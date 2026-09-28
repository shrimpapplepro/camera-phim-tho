@preconcurrency import AVFoundation
import Observation
import SwiftUI

/// UI-side state. Mirrors the capture service and sends it intents through one ordered stream.
@MainActor
@Observable
final class CameraModel {
    enum Status: Equatable { case starting, running, unauthorized, failed(String) }

    let service = CaptureService()
    @ObservationIgnored private let intentStream: AsyncStream<CameraIntent>
    @ObservationIgnored private let intents: AsyncStream<CameraIntent>.Continuation

    var status: Status = .starting
    var lenses: [LensOption] = []
    var lensID = ""
    var capabilities = CameraCapabilities()
    var controls = ControlState()
    var readout = LiveReadout()
    var lastCapture: CaptureResult?
    var captureCount = 0
    var message: String?
    var systemControlsFullscreen = false
    var focusReticle: CGPoint?
    /// A capture waiting for watermark review. The shutter is disabled while it is set.
    var pendingReview: PendingCapture?
    var showFilters = false {
        didSet {
            guard showFilters != oldValue else { return }
            if showFilters { selected = nil; thumbnails.removeAll() }
            updateFilterFrames()
        }
    }
    var selected: Parameter? {
        didSet { if selected != nil, showFilters { showFilters = false } }
    }

    let library = LUTLibrary.shared
    @ObservationIgnored private var thumbnails: [String: UIImage] = [:]
    @ObservationIgnored private var loadedCube: (id: String, cube: CubeLUT)?
    @ObservationIgnored private var filterLoadTask: Task<Void, Never>?

    var preferences: Preferences {
        didSet {
            guard preferences != oldValue else { return }
            preferences.save()
            intents.yield(.setPreferences(preferences))
            if preferences.meterMode != oldValue.meterMode { updateFilterFrames() }
            publishAppContext()
            if preferences.rememberControls != oldValue.rememberControls {
                Preferences.saveControls(preferences.rememberControls ? controls : nil)
            }
        }
    }

    @ObservationIgnored private weak var previewLayer: AVCaptureVideoPreviewLayer?
    @ObservationIgnored private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    @ObservationIgnored private var rotationObservation: NSKeyValueObservation?
    @ObservationIgnored private var messageTask: Task<Void, Never>?
    @ObservationIgnored private var reticleTask: Task<Void, Never>?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var contextTask: Task<Void, Never>?

    init() {
        (intentStream, intents) = AsyncStream.makeStream(of: CameraIntent.self)
        preferences = Preferences.load()
        if preferences.rememberControls, let saved = Preferences.loadControls() {
            controls = saved
        }
    }

    func start() {
        guard !started else { return }
        started = true
        publishAppContext()
        let service = service
        let stream = intentStream
        let prefs = preferences
        let initial = controls
        Task.detached { await service.run(intents: stream, preferences: prefs, initialControls: initial) }
        Task {
            for await event in service.events { handle(event) }
        }
    }

    private func handle(_ event: CameraEvent) {
        switch event {
        case .configured(let lenses, let lensID, let caps, let controls):
            self.lenses = lenses
            self.lensID = lensID
            self.capabilities = caps
            self.controls = controls
            if selected == .aperture, !caps.hasVariableAperture { selected = nil }
            let firstConfiguration = status != .running
            status = .running
            rebuildRotationCoordinator()
            if firstConfiguration { applyFilter() }
        case .controls(let controls):
            self.controls = controls
            persistControls()
        case .readout(let readout):
            self.readout = readout
        case .willCapture:
            captureCount += 1
        case .review(let pending):
            pendingReview = pending
        case .captured(let result):
            lastCapture = result
        case .message(let text):
            show(text)
        case .unauthorized:
            status = .unauthorized
        case .failed(let reason):
            status = .failed(reason)
        case .framing(let aspect):
            withAnimation(.smooth(duration: 0.35)) { capabilities.frameAspect = aspect }
        case .systemControlsFullscreen(let fullscreen):
            withAnimation(.smooth) { systemControlsFullscreen = fullscreen }
        }
    }

    // MARK: Intents

    func update(_ mutate: (inout ControlState) -> Void) {
        var next = controls
        mutate(&next)
        guard next != controls else { return }
        controls = next
        intents.yield(.setControls(next))
        persistControls()
    }

    func isAuto(_ parameter: Parameter) -> Bool {
        switch parameter {
        case .aperture: controls.aperture == nil
        case .shutter: controls.shutter == nil
        case .iso: controls.iso == nil
        case .bias: controls.bias == 0
        case .whiteBalance: controls.temperature == nil
        case .focus: controls.focus == nil
        }
    }

    func isAvailable(_ parameter: Parameter) -> Bool {
        switch parameter {
        case .aperture: capabilities.hasVariableAperture
        case .focus: capabilities.manualFocus
        case .whiteBalance: capabilities.manualWhiteBalance
        case .bias: true
        case .shutter, .iso: true
        }
    }

    /// Bias only changes the picture while at least one exposure axis is Auto.
    var biasIsEffective: Bool {
        !capabilities.adjustableAxes.isSubset(of: controls.manualAxes)
    }

    /// Switch a parameter between Auto and Manual. Manual starts from the live value,
    /// so the picture doesn't jump.
    func setAuto(_ parameter: Parameter, _ auto: Bool) {
        let r = readout
        let c = capabilities
        update { s in
            switch parameter {
            case .aperture:
                s.aperture = auto ? nil : snappedAperture(r.aperture > 0 ? r.aperture : c.apertureStops.first ?? 1.8)
            case .shutter:
                s.shutter = auto ? nil : (r.shutter > 0 ? r.shutter : 1.0 / 125).clamped(to: c.shutterRange)
            case .iso:
                s.iso = auto ? nil : (r.iso > 0 ? r.iso : 100).clamped(to: c.isoRange)
            case .bias:
                s.bias = 0
            case .whiteBalance:
                s.temperature = auto ? nil : r.temperature.clamped(to: 2000...10000)
                s.tint = auto ? 0 : r.tint.clamped(to: -150...150)
            case .focus:
                s.focus = auto ? nil : r.lensPosition.clamped(to: 0...1)
            }
        }
    }

    func resetAllToAuto() {
        update { $0 = ControlState() }
    }

    func snappedAperture(_ value: Float) -> Float {
        let c = capabilities
        guard preferences.snapApertureToStops, !c.apertureStops.isEmpty else {
            return value.clamped(to: c.apertureRange)
        }
        return c.apertureStops[ExposureMath.nearestIndex(of: value, in: c.apertureStops)]
    }

    func selectLens(_ id: String) {
        guard id != lensID else { return }
        intents.yield(.selectLens(id))
    }

    var rearLenses: [LensOption] { lenses.filter { !$0.isFront } }
    var frontLens: LensOption? { lenses.first(where: \.isFront) }
    var isFrontActive: Bool { frontLens?.id == lensID }
    @ObservationIgnored private var lastRearLensID: String?

    var isLandscapeFraming: Bool { capabilities.frameAspect > 1 }

    /// Open-gate front camera: swap portrait ⇄ landscape without rotating the phone.
    func toggleFraming() {
        guard capabilities.canSwapFraming else { return }
        intents.yield(.setLandscapeFraming(!isLandscapeFraming))
    }

    /// Front ⇄ rear. Going back returns to the rear lens you were last on.
    func flipCamera() {
        guard let front = frontLens else { return }
        if isFrontActive {
            selectLens(lastRearLensID ?? rearLenses.first(where: { $0.label == "1×" })?.id ?? rearLenses.first?.id ?? front.id)
        } else {
            lastRearLensID = lensID
            selectLens(front.id)
        }
    }

    func capture() {
        guard status == .running, !readout.isInterrupted, pendingReview == nil else { return }
        guard capabilities.rawAvailable else {
            show(String(localized: "RAW capture isn't available on this lens."))
            return
        }
        let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture ?? 90
        intents.yield(.capture(rotationAngle: angle, filter: preferences.filter, grain: preferences.grain,
                               watermark: preferences.watermark))
    }

    /// Save the reviewed capture with the chosen watermark (which also becomes the default).
    func saveReview(watermark: WatermarkSettings) {
        guard let pending = pendingReview else { return }
        preferences.watermark = watermark
        pendingReview = nil
        intents.yield(.finishCapture(pending, watermark: watermark))
    }

    func discardReview() {
        pendingReview = nil
    }

    func setActive(_ active: Bool) {
        intents.yield(.setActive(active))
    }

    // MARK: Preview

    func attach(previewLayer: AVCaptureVideoPreviewLayer, filterLayer: CAMetalLayer) {
        self.previewLayer = previewLayer
        service.renderer.setLayer(filterLayer)
        rebuildRotationCoordinator()
    }

    func tap(atLayerPoint point: CGPoint) {
        guard let layer = previewLayer else { return }
        let devicePoint = layer.captureDevicePointConverted(fromLayerPoint: point)
        intents.yield(.pointOfInterest(devicePoint))
        // Spot metering runs on upright, as-displayed frames: use the view's own coordinates.
        let size = layer.bounds.size
        if size.width > 0, size.height > 0 {
            service.renderer.setSpot(CGPoint(x: point.x / size.width, y: point.y / size.height))
        }
        guard preferences.showFocusReticle else { return }
        focusReticle = point
        reticleTask?.cancel()
        reticleTask = Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { focusReticle = nil }
        }
    }

    private func rebuildRotationCoordinator() {
        guard let layer = previewLayer, !lensID.isEmpty,
              let device = AVCaptureDevice(uniqueID: lensID) else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: layer)
        rotationCoordinator = coordinator
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { [weak self] coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            Task { @MainActor in self?.applyPreviewAngle(angle) }
        }
    }

    private func applyPreviewAngle(_ angle: CGFloat) {
        intents.yield(.setPreviewRotation(angle))
        guard let connection = previewLayer?.connection, connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
    }

    // MARK: Filters

    var filterInfo: LUTInfo? { preferences.filter.flatMap { library.info($0.id) } }

    // MARK: Favorite looks

    /// Favorites that still exist in the installed library.
    var favoriteLooks: [LUTInfo] { preferences.favoriteLooks.compactMap { library.info($0) } }

    func isFavorite(_ id: String) -> Bool { preferences.favoriteLooks.contains(id) }

    func addFavorite(_ info: LUTInfo) {
        guard !isFavorite(info.id) else {
            show(String(localized: "\(info.name) is already in Favorites."))
            return
        }
        preferences.favoriteLooks.append(info.id)
        show(String(localized: "Added \(info.name) to Favorites."))
    }

    func removeFavorite(_ info: LUTInfo) {
        preferences.favoriteLooks.removeAll { $0 == info.id }
        show(String(localized: "Removed \(info.name) from Favorites."))
    }

    /// A look is active when a LUT or grain is on. With no look, the viewfinder is the
    /// untouched system preview and only the DNG is saved.
    var lookActive: Bool { preferences.filter != nil || preferences.grain.isActive }

    func setGrain(_ mutate: (inout GrainSettings) -> Void) {
        let wasActive = preferences.grain.isActive
        mutate(&preferences.grain)
        service.renderer.setGrain(preferences.grain)
        if wasActive != preferences.grain.isActive { updateFilterFrames() }
    }

    func selectFilter(_ id: String?) {
        guard let id else {
            preferences.filter = nil
            applyFilter()
            return
        }
        let intensity = preferences.filter?.intensity ?? 1
        preferences.filter = FilterSelection(id: id, intensity: intensity)
        applyFilter()
    }

    func setFilterIntensity(_ value: Float) {
        guard var filter = preferences.filter else { return }
        filter.intensity = value.clamped(to: 0...1)
        preferences.filter = filter
        if let loaded = loadedCube, loaded.id == filter.id {
            service.renderer.setFilter(loaded.cube, intensity: filter.intensity)
        }
    }

    /// Load the selected LUT off the main thread and hand it to the viewfinder renderer.
    private func applyFilter() {
        service.renderer.setGrain(preferences.grain)
        updateFilterFrames()
        filterLoadTask?.cancel()
        guard let selection = preferences.filter else {
            loadedCube = nil
            service.renderer.setFilter(nil, intensity: 1)
            return
        }
        if let loaded = loadedCube, loaded.id == selection.id {
            service.renderer.setFilter(loaded.cube, intensity: selection.intensity)
            return
        }
        let library = library
        filterLoadTask = Task {
            let cube = await Task.detached(priority: .userInitiated) { library.cube(for: selection.id) }.value
            guard !Task.isCancelled, preferences.filter?.id == selection.id else { return }
            guard let cube else {
                show(String(localized: "That filter couldn't be loaded."))
                preferences.filter = nil
                applyFilter()
                return
            }
            loadedCube = (selection.id, cube)
            service.renderer.setFilter(cube, intensity: preferences.filter?.intensity ?? 1)
        }
    }

    /// Frames flow to the renderer only while a filter is active or the browser needs a snapshot.
    private func updateFilterFrames() {
        intents.yield(.setFilterFrames(lookActive || showFilters || preferences.meterMode != .system))
    }

    /// A small preview of the current scene through a LUT, rendered off the main thread.
    func thumbnail(for id: String) async -> UIImage? {
        if let cached = thumbnails[id] { return cached }
        let renderer = service.renderer
        let library = library
        var snapshot = renderer.latestSnapshot()
        for _ in 0..<20 where snapshot == nil {       // the first frames may not have arrived yet
            try? await Task.sleep(for: .milliseconds(50))
            snapshot = renderer.latestSnapshot()
        }
        guard let snapshot else { return nil }
        let image = await Task.detached(priority: .utility) { () -> UIImage? in
            guard let cube = library.cube(for: id) else { return nil }
            let output = LUTLibrary.apply(cube, to: snapshot, intensity: 1)
            guard let cg = renderer.ciContext.createCGImage(output, from: snapshot.extent) else { return nil }
            return UIImage(cgImage: cg)
        }.value
        if let image { thumbnails[id] = image }
        return image
    }

    // MARK: Helpers

    private func persistControls() {
        if preferences.rememberControls {
            Preferences.saveControls(controls)
            publishAppContext()
        }
    }

    // MARK: Lock Screen camera

    /// Hands the current settings to the Lock Screen camera through the capture intent's app
    /// context (the extension can't read the app's preferences while the device is locked).
    /// Debounced, because dial drags change controls many times a second.
    private func publishAppContext() {
        guard !AppRuntime.isExtension else { return }
        guard let prefsData = try? JSONEncoder().encode(preferences) else { return }
        let controlsData = preferences.rememberControls ? try? JSONEncoder().encode(controls) : nil
        let context = TrueShotCaptureContext(preferences: prefsData, controls: controlsData)
        contextTask?.cancel()
        contextTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            try? await TrueShotCaptureIntent.updateAppContext(context)
        }
    }

    /// Applies settings published by the app (Lock Screen camera only).
    func applyAppContext(_ context: TrueShotCaptureContext) {
        if let prefs = try? JSONDecoder().decode(Preferences.self, from: context.preferences) {
            preferences = prefs
        }
        if let data = context.controls, let saved = try? JSONDecoder().decode(ControlState.self, from: data) {
            update { $0 = saved }
        }
    }

    func show(_ text: String) {
        withAnimation(.smooth) { message = text }
        messageTask?.cancel()
        messageTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.smooth) { message = nil }
        }
    }
}
