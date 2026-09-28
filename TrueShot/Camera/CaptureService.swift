@preconcurrency import AVFoundation
import ImageIO
import Photos
import UIKit

/// Owns the AVCaptureSession. Every method runs on `sessionQueue`, which is the actor's
/// executor, so device configuration and Camera Control actions share one exclusive
/// execution context (as AVCaptureSlider / AVCaptureIndexPicker require).
///
/// Capture policy ("true to life"): Bayer RAW only, saved as DNG. No Apple ProRAW, no
/// processed HEIC/JPEG, no Deep Fusion / Smart HDR / Photonic Engine
/// (`photoQualityPrioritization = .speed`), no digital zoom (Bayer RAW requires 1×).
actor CaptureService {
    nonisolated let session = AVCaptureSession()
    nonisolated let events: AsyncStream<CameraEvent>
    private nonisolated let sink: AsyncStream<CameraEvent>.Continuation
    private nonisolated let sessionQueue = DispatchSerialQueue(label: "TrueShot.session", qos: .userInitiated)
    private nonisolated let controlsDelegate: SessionControlsDelegate

    nonisolated var unownedExecutor: UnownedSerialExecutor { sessionQueue.asUnownedSerialExecutor() }

    /// Draws the filtered viewfinder; fed by `videoOutput` only while a filter is in use.
    nonisolated let renderer = FilterRenderer()

    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private var input: AVCaptureDeviceInput?
    private var device: AVCaptureDevice? { input?.device }

    private var lenses: [LensOption] = []
    private var devicesByID: [String: AVCaptureDevice] = [:]
    private var caps = CameraCapabilities()
    private var controls = ControlState()
    private var applied: ControlState?
    private var prefs = Preferences()
    private var isConfigured = false
    private var isActive = true
    private var lastRestartAttempt = Date.distantPast
    private var inFlight: [Int64: PhotoCaptureProcessor] = [:]
    private var readoutTask: Task<Void, Never>?

    // TrueShot meter: an outer loop that steers Apple AE through exposure bias.
    private var meterBias: Float = 0          // added on top of the user's bias
    private var meterReading: Float?          // latest wanted change, stops (+ = brighter)
    private var lastMeterStep = Date.distantPast
    private var wantAtLastStep: Float?        // error when the last step was taken
    private var stalledSteps = 0              // consecutive steps that didn't reduce the error

    // Camera Control (the side button on iPhone 16 and later).
    private var apertureSlider: AVCaptureSlider?
    private var shutterPicker: AVCaptureIndexPicker?
    private var isoPicker: AVCaptureIndexPicker?
    private var focusSlider: AVCaptureSlider?
    private var shutterStops: [Double] = []
    private var isoStops: [Float] = []

    init() {
        let (stream, continuation) = AsyncStream.makeStream(of: CameraEvent.self)
        events = stream
        sink = continuation
        controlsDelegate = SessionControlsDelegate { fullscreen in
            continuation.yield(.systemControlsFullscreen(fullscreen))
        }
    }

    // MARK: - Lifecycle

    func run(intents: AsyncStream<CameraIntent>, preferences: Preferences, initialControls: ControlState) async {
        prefs = preferences
        controls = initialControls
        installMeter()

        guard await AVCaptureDevice.requestAccess(for: .video) else {
            sink.yield(.unauthorized)
            return
        }
        do {
            try configureSession()
        } catch {
            sink.yield(.failed(error.localizedDescription))
            return
        }
        // After commitConfiguration, so the photo output reports this lens's RAW formats.
        deviceDidChange()
        session.startRunning()
        startReadouts()

        for await intent in intents {
            handle(intent)
        }
    }

    private func handle(_ intent: CameraIntent) {
        switch intent {
        case .setControls(let requested):
            let accepted = sanitized(requested, promoteFrom: controls)
            controls = accepted
            applyControls()
            syncSystemControls()
            if accepted != requested { sink.yield(.controls(accepted)) }
        case .selectLens(let id):
            selectLens(id)
        case .pointOfInterest(let point):
            focusAndExpose(at: point)
            renderer.setSpot(point)
        case .capture(let angle, let filter, let grain, let watermark):
            Task { await capture(rotationAngle: angle, filter: filter, grain: grain, watermark: watermark) }
        case .setFilterFrames(let enabled):
            videoOutput.connection(with: .video)?.isEnabled = enabled
        case .finishCapture(let pending, let watermark):
            Task { await finish(pending, watermark: watermark) }
        case .setPreferences(let newPrefs):
            let meterChanged = newPrefs.meterMode != prefs.meterMode
            let flashChanged = newPrefs.flash != prefs.flash
            let rebuildControls = newPrefs.cameraControlItems != prefs.cameraControlItems
            let deviceChanged = newPrefs.faceDrivenAutoExposure != prefs.faceDrivenAutoExposure
                || newPrefs.automaticExposureSignals != prefs.automaticExposureSignals
                || newPrefs.enabledExposureSignals != prefs.enabledExposureSignals
                || newPrefs.apertureSpeed != prefs.apertureSpeed
            prefs = newPrefs
            if deviceChanged, let device { applyPreferences(to: device) }
            if rebuildControls { rebuildSystemControls() }
            if meterChanged { installMeter(); resetMeter() }
            if flashChanged, let device { applyFlashRecipe(to: device) }
        case .setActive(let active):
            isActive = active
            guard isConfigured else { return }
            if active, !session.isRunning { session.startRunning() }
            if !active, session.isRunning { session.stopRunning() }
        }
    }

    // MARK: - Session configuration

    private func configureSession() throws {
        discoverLenses()
        let initial = lenses.first { devicesByID[$0.id]?.deviceType == .builtInWideAngleCamera } ?? lenses.first
        guard let initial, let camera = devicesByID[initial.id] else { throw CameraError.noCamera }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if session.canSetSessionPreset(.photo) { session.sessionPreset = .photo }

        let newInput = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(newInput) else { throw CameraError.cannotAddInput }
        session.addInput(newInput)
        input = newInput

        guard session.canAddOutput(photoOutput) else { throw CameraError.cannotAddOutput }
        session.addOutput(photoOutput)
        // Cap the pipeline at .speed: this disables multi-frame fusion (Deep Fusion,
        // Smart HDR, Night mode) and is mandatory for Bayer RAW.
        photoOutput.maxPhotoQualityPrioritization = .speed

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(renderer, queue: renderer.videoQueue)
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
            videoOutput.connection(with: .video)?.isEnabled = false
        }

        if session.supportsControls {
            session.setControlsDelegate(controlsDelegate, queue: sessionQueue)
        }
        isConfigured = true
    }

    private func discoverLenses() {
        let types: [AVCaptureDevice.DeviceType] = [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera]
        let found = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .back).devices

        // Derive "0.5× / 1× / 4×" labels from the virtual device's switch-over factors.
        var multipliers: [String: Double] = [:]
        let virtual = AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInDualCamera, for: .video, position: .back)
        if let virtual {
            let constituents = virtual.constituentDevices
            let factors = [1.0] + virtual.virtualDeviceSwitchOverVideoZoomFactors.map(\.doubleValue)
            if factors.count == constituents.count,
               let wide = constituents.firstIndex(where: { $0.deviceType == .builtInWideAngleCamera }) {
                for (i, c) in constituents.enumerated() {
                    multipliers[c.uniqueID] = factors[i] / factors[wide]
                }
            }
        }

        let order: [AVCaptureDevice.DeviceType: Int] = [.builtInUltraWideCamera: 0, .builtInWideAngleCamera: 1, .builtInTelephotoCamera: 2]
        let sorted = found.sorted { (order[$0.deviceType] ?? 9) < (order[$1.deviceType] ?? 9) }

        lenses = sorted.map { device in
            let multiplier = multipliers[device.uniqueID] ?? {
                switch device.deviceType {
                case .builtInUltraWideCamera: 0.5
                case .builtInTelephotoCamera: 3
                default: 1
                }
            }()
            return LensOption(id: device.uniqueID, label: Self.zoomLabel(multiplier), name: device.localizedName)
        }
        devicesByID = Dictionary(uniqueKeysWithValues: sorted.map { ($0.uniqueID, $0) })
    }

    private static func zoomLabel(_ m: Double) -> String {
        let r = (m * 10).rounded() / 10
        return r == r.rounded() ? "\(Int(r))×" : String(format: "%.1f×", r)
    }

    private func selectLens(_ id: String) {
        guard let camera = devicesByID[id], camera.uniqueID != device?.uniqueID,
              let newInput = try? AVCaptureDeviceInput(device: camera) else { return }

        session.beginConfiguration()
        let old = input
        if let old { session.removeInput(old) }
        if session.canAddInput(newInput) {
            session.addInput(newInput)
            input = newInput
        } else if let old {
            session.addInput(old)
            sink.yield(.message(String(localized: "Couldn't switch to that lens.")))
        }
        session.commitConfiguration()
        photoOutput.maxPhotoQualityPrioritization = .speed
        deviceDidChange()
    }

    /// Recompute capabilities for the active lens, clamp the user's controls to them,
    /// and re-apply everything.
    private func deviceDidChange() {
        guard let device else { return }
        caps = makeCapabilities(for: device)
        applied = nil
        // Lens positions are per-lens (0.272 is a different distance on each), so a manual focus
        // from the previous lens is meaningless here: return to autofocus.
        let focusWasManual = controls.focus != nil
        controls.focus = nil
        meterBias = 0
        meterReading = nil
        wantAtLastStep = nil
        stalledSteps = 0
        applyPreferences(to: device)
        applyFlashRecipe(to: device)
        controls = sanitized(controls, promoteFrom: controls)
        applyControls()
        rebuildSystemControls()
        sink.yield(.configured(lenses: lenses, lensID: device.uniqueID, capabilities: caps, controls: controls))
        if focusWasManual {
            sink.yield(.message(String(localized: "Focus returned to auto for this lens.")))
        }
    }

    private func makeCapabilities(for device: AVCaptureDevice) -> CameraCapabilities {
        let format = device.activeFormat
        var c = CameraCapabilities()
        c.lensID = device.uniqueID

        let minA = format.minLensAperture, maxA = format.maxLensAperture
        let stops = format.recommendedLensApertureStops.sorted()
        if minA > 0, maxA >= minA {
            c.apertureRange = minA...maxA
        } else {
            c.apertureRange = device.lensAperture...device.lensAperture
        }
        c.apertureStops = stops.isEmpty ? [device.lensAperture] : stops
        // Per the SDK: a single recommended stop means the aperture is fixed.
        c.hasVariableAperture = stops.count > 1 && maxA > minA

        c.shutterRange = format.minExposureDuration.seconds...format.maxExposureDuration.seconds
        c.isoRange = format.minISO...format.maxISO
        c.biasRange = device.minExposureTargetBias...device.maxExposureTargetBias
        c.manualFocus = device.isLockingFocusWithCustomLensPositionSupported
        c.minimumFocusDistance = device.minimumFocusDistance   // mm, -1 if unknown
        c.manualWhiteBalance = device.isLockingWhiteBalanceWithCustomDeviceGainsSupported
        c.rawAvailable = photoOutput.availableRawPhotoPixelFormatTypes.contains { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) }
        c.hasFlash = device.hasTorch   // the LED is driven as a torch burst (see fireLED)
        c.supportedExposureSignals = device.supportedExposureSignals.map(\.rawValue).sorted()

        // Which priority modes does this format accept? "Current" stands for "locked".
        var combos: Set<UInt8> = [0]
        for mask in UInt8(1)..<8 {
            let axes = ManualAxes(rawValue: mask)
            if axes.contains(.aperture) && !c.hasVariableAperture { continue }
            let a: Float = c.hasVariableAperture
                ? (axes.contains(.aperture) ? AVCaptureDevice.currentLensAperture : AVCaptureDevice.autoLensAperture)
                : AVCaptureDevice.currentLensAperture
            let d = axes.contains(.shutter) ? AVCaptureDevice.currentExposureDuration : AVCaptureDevice.autoExposureDuration
            let i = axes.contains(.iso) ? AVCaptureDevice.currentISO : AVCaptureDevice.autoISO
            if format.supportsExposureModeCustom(lensAperture: a, duration: d, iso: i) {
                combos.insert(mask)
            }
        }
        c.supportedCombos = combos
        return c
    }

    // MARK: - Applying controls

    /// Clamp every value to what the lens supports. If the requested set of manual axes is
    /// not an accepted priority mode, lock the remaining axes at their current values
    /// (full manual is always accepted).
    private func sanitized(_ requested: ControlState, promoteFrom previous: ControlState) -> ControlState {
        var s = requested
        s.aperture = caps.hasVariableAperture ? s.aperture?.clamped(to: caps.apertureRange) : nil
        s.shutter = s.shutter?.clamped(to: caps.shutterRange)
        s.iso = s.iso?.clamped(to: caps.isoRange)
        s.bias = s.bias.clamped(to: caps.biasRange)
        s.focus = caps.manualFocus ? s.focus?.clamped(to: 0...1) : nil
        s.temperature = caps.manualWhiteBalance ? s.temperature?.clamped(to: 2000...10000) : nil
        s.tint = s.tint.clamped(to: -150...150)

        if !caps.supportedCombos.contains(s.manualAxes.rawValue), let device {
            if caps.hasVariableAperture, s.aperture == nil { s.aperture = device.lensAperture.clamped(to: caps.apertureRange) }
            if s.shutter == nil { s.shutter = device.exposureDuration.seconds.clamped(to: caps.shutterRange) }
            if s.iso == nil { s.iso = device.iso.clamped(to: caps.isoRange) }
            if s.manualAxes != requested.manualAxes, requested.manualAxes != previous.manualAxes {
                sink.yield(.message(String(localized: "That priority mode isn't supported on this lens, so the other settings were locked too.")))
            }
        }
        return s
    }

    private func applyControls() {
        guard let device else { return }
        do { try device.lockForConfiguration() } catch {
            sink.yield(.message(String(localized: "The camera is busy.")))
            return
        }
        defer { device.unlockForConfiguration() }

        let prev = applied
        let exposureChanged = prev == nil || prev?.aperture != controls.aperture
            || prev?.shutter != controls.shutter || prev?.iso != controls.iso
        if exposureChanged { applyExposure(device) }

        if exposureChanged || prev?.bias != controls.bias {
            let bias = (controls.bias + meterBias).clamped(to: device.minExposureTargetBias...device.maxExposureTargetBias)
            device.setExposureTargetBias(bias, completionHandler: nil)
        }

        if let position = controls.focus, device.isLockingFocusWithCustomLensPositionSupported {
            if prev?.focus != position {
                device.setFocusModeLocked(lensPosition: position.clamped(to: 0...1), completionHandler: nil)
            }
        } else if prev == nil || prev?.focus != nil {
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        }

        if let kelvin = controls.temperature, device.isLockingWhiteBalanceWithCustomDeviceGainsSupported {
            if prev?.temperature != kelvin || prev?.tint != controls.tint {
                let values = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: kelvin, tint: controls.tint)
                let gains = clampedGains(device.deviceWhiteBalanceGains(for: values), max: device.maxWhiteBalanceGain)
                device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
            }
        } else if prev == nil || prev?.temperature != nil {
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
        }
        applied = controls
    }

    private func applyExposure(_ device: AVCaptureDevice) {
        let format = device.activeFormat
        if controls.manualAxes.isEmpty {
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            return
        }
        guard device.isExposureModeSupported(.custom) else { return }

        let aperture: Float
        if caps.hasVariableAperture {
            aperture = controls.aperture.map { $0.clamped(to: format.minLensAperture...format.maxLensAperture) }
                ?? AVCaptureDevice.autoLensAperture
        } else {
            aperture = AVCaptureDevice.currentLensAperture
        }
        let duration: CMTime = controls.shutter.map { seconds in
            CMTime(seconds: seconds, preferredTimescale: 1_000_000_000)
                .clamped(to: format.minExposureDuration...format.maxExposureDuration)
        } ?? AVCaptureDevice.autoExposureDuration
        let iso: Float = controls.iso.map { $0.clamped(to: format.minISO...format.maxISO) } ?? AVCaptureDevice.autoISO

        guard format.supportsExposureModeCustom(lensAperture: aperture, duration: duration, iso: iso) else {
            sink.yield(.message(String(localized: "This exposure combination isn't supported on this lens.")))
            return
        }
        device.setExposureModeCustom(lensAperture: aperture, duration: duration, iso: iso, completionHandler: nil)
    }

    private func clampedGains(_ g: AVCaptureDevice.WhiteBalanceGains, max: Float) -> AVCaptureDevice.WhiteBalanceGains {
        var g = g
        g.redGain = g.redGain.clamped(to: 1...max)
        g.greenGain = g.greenGain.clamped(to: 1...max)
        g.blueGain = g.blueGain.clamped(to: 1...max)
        return g
    }

    private func applyPreferences(to device: AVCaptureDevice) {
        do { try device.lockForConfiguration() } catch { return }
        defer { device.unlockForConfiguration() }

        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.automaticallyAdjustsFaceDrivenAutoExposureEnabled = false
            device.isFaceDrivenAutoExposureEnabled = prefs.faceDrivenAutoExposure
            if device.exposureMode == .continuousAutoExposure {
                device.exposureMode = .continuousAutoExposure   // re-apply so the change takes effect
            }
        }

        device.automaticallyEnablesExposureSignals = prefs.automaticExposureSignals
        if !prefs.automaticExposureSignals {
            let wanted = Set(prefs.enabledExposureSignals)
            device.enabledExposureSignals = device.supportedExposureSignals.filter { wanted.contains($0.rawValue) }
        }

        if caps.hasVariableAperture {
            device.autoExposureLensApertureRateLimit = prefs.apertureSpeed.rateLimit
        }
    }

    private func focusAndExpose(at point: CGPoint) {
        guard let device, (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }
        let p = CGPoint(x: point.x.clamped(to: 0...1), y: point.y.clamped(to: 0...1))

        if controls.focus == nil, device.isFocusPointOfInterestSupported,
           device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusPointOfInterest = p
            device.focusMode = .continuousAutoFocus
        }
        if controls.manualAxes.isEmpty, device.isExposurePointOfInterestSupported,
           device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposurePointOfInterest = p
            device.exposureMode = .continuousAutoExposure
        }
    }

    // MARK: - Flash

    /// True while a flash capture is in progress; the meter holds still meanwhile.
    private var capturingWithFlash = false
    /// Latest frame statistics from the meter (used as TTL metering for the LED flash).
    private var lastMeterStats: (stats: MeterStats, time: Date)?

    /// Slowest shutter auto exposure may choose while a flash mode is on — in the live view and so
    /// for the LED-lit capture: Point & Shoot 1/60 s (freeze the subject), On 1/30 s.
    private func applyFlashRecipe(to device: AVCaptureDevice) {
        guard (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }
        let format = device.activeFormat
        let slowest: Double? = switch prefs.flash {
        case .pointAndShoot: Preferences.Flash.pointAndShootSlowestShutter
        case .on: 1.0 / 30
        case .off, .auto: nil
        }
        if let slowest {
            device.activeMaxExposureDuration = CMTime(seconds: slowest, preferredTimescale: 1_000_000_000)
                .clamped(to: format.minExposureDuration...format.maxExposureDuration)
        } else {
            device.activeMaxExposureDuration = .invalid   // back to the device default
        }
    }

    /// Auto flash: fire only in dim light (EV100 below 6, i.e. a dim interior).
    private static func isDim(_ device: AVCaptureDevice) -> Bool {
        let n = Double(device.lensAperture), t = device.exposureDuration.seconds, iso = Double(device.iso)
        guard n > 0, t > 0, iso > 0 else { return false }
        return log2(n * n / t) - log2(iso / 100) < 6
    }

    /// Turns the LED on at full power, lets auto exposure settle on the lit scene, then corrects it
    /// with TrueShot's own meter (highlight protection keeps a close, lit subject from clipping — plain
    /// AE averages in the dark background and overexposes it) and locks the result for the capture.
    /// Manually set shutter/ISO are kept. Returns the exposure the capture should get.
    private func fireLED(on device: AVCaptureDevice) async -> (seconds: Double, iso: Float) {
        capturingWithFlash = true
        if (try? device.lockForConfiguration()) != nil {
            try? device.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
            // The meter correction was for the unlit room; the lit scene is metered fresh.
            device.setExposureTargetBias(controls.bias.clamped(to: device.minExposureTargetBias...device.maxExposureTargetBias),
                                         completionHandler: nil)
            device.unlockForConfiguration()
        }
        let lit = Date()
        try? await Task.sleep(for: .milliseconds(180))
        for _ in 0..<10 where device.isAdjustingExposure { try? await Task.sleep(for: .milliseconds(60)) }
        for _ in 0..<6 where (lastMeterStats?.time ?? .distantPast) < lit.addingTimeInterval(0.15) {
            try? await Task.sleep(for: .milliseconds(50))                    // a frame metered with the LED on
        }

        let format = device.activeFormat
        var t = controls.shutter ?? device.exposureDuration.seconds
        var iso = controls.iso ?? device.iso
        var ttl: Float = 0
        if prefs.meterMode != .system, let reading = lastMeterStats, reading.time > lit {
            ttl = Meter.correction(reading.stats, mode: prefs.meterMode).clamped(to: -3...1)
        }
        // Right after the LED comes on, AE sometimes settles on a strange split with the right total
        // (seen on device: 1/3425 s at ISO 9446 ≈ 1/60 s at ISO 165). Re-balance to the slowest
        // allowed shutter at the lowest ISO, before the TTL correction and the ISO cap — otherwise
        // the cap throws the light away (that shot came out 3.5 EV dark).
        // 1/60 s is the classic flash sync speed: sharp handheld under a continuous LED, lowest ISO.
        if controls.shutter == nil, controls.iso == nil {
            let target = Preferences.Flash.pointAndShootSlowestShutter
            iso *= Float(t / target)
            t = target
        }
        if controls.iso == nil {
            iso *= powf(2, ttl)
            // Point & Shoot's film-like ISO ceiling applies only while the shutter is automatic; a
            // shutter the user picked gets full auto-ISO compensation.
            if prefs.flash == .pointAndShoot, controls.shutter == nil { iso = min(iso, 800) }
        } else if controls.shutter == nil {
            t *= Double(powf(2, ttl))
        }
        let duration = CMTime(seconds: t, preferredTimescale: 1_000_000_000)
            .clamped(to: format.minExposureDuration...format.maxExposureDuration)
        iso = iso.clamped(to: format.minISO...format.maxISO)

        if device.isExposureModeSupported(.custom), (try? device.lockForConfiguration()) != nil {
            let aperture = AVCaptureDevice.currentLensAperture
            if format.supportsExposureModeCustom(lensAperture: aperture, duration: duration, iso: iso) {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    device.setExposureModeCustom(lensAperture: aperture, duration: duration, iso: iso) { _ in continuation.resume() }
                }
            }
            device.unlockForConfiguration()
        }
        return (duration.seconds, iso)
    }

    /// LED off; the user's exposure modes, bias and meter correction come back.
    private func releaseLED() {
        if let device, (try? device.lockForConfiguration()) != nil {
            device.torchMode = .off
            device.unlockForConfiguration()
        }
        capturingWithFlash = false
        applied = nil
        applyControls()
    }

    // MARK: - Metering

    private func installMeter() {
        var handler: (@Sendable (MeterStats) -> Void)?
        if prefs.meterMode != .system {
            handler = { @Sendable stats in
                Task { await self.meterUpdate(stats) }
            }
        }
        renderer.setMeter(mode: prefs.meterMode, handler: handler)
    }

    private func resetMeter() {
        meterBias = 0
        meterReading = nil
        wantAtLastStep = nil
        stalledSteps = 0
        guard let device, (try? device.lockForConfiguration()) != nil else { return }
        device.setExposureTargetBias(controls.bias.clamped(to: device.minExposureTargetBias...device.maxExposureTargetBias),
                                     completionHandler: nil)
        device.unlockForConfiguration()
    }

    /// One step of the metering loop. Deliberately slow and damped so it never hunts:
    /// deadband 0.25 EV, at most 0.3 EV per step, ≥ 0.25 s apart, only while AE has settled,
    /// and it stops pushing when its steps stop having an effect (see stall detection).
    private func meterUpdate(_ stats: MeterStats) {
        lastMeterStats = (stats, Date())
        guard prefs.meterMode != .system, isActive, !capturingWithFlash, let device else { return }
        let want = Meter.correction(stats, mode: prefs.meterMode)
        meterReading = want

        // Full manual: TrueShot's meter is a light meter only.
        guard !caps.adjustableAxes.isSubset(of: controls.manualAxes) else { return }
        guard !device.isAdjustingExposure, abs(want) >= 0.25,
              Date().timeIntervalSince(lastMeterStep) >= 0.25 else { return }

        // Stall detection. The preview is processed by an adaptive tone curve that partly cancels
        // small exposure changes, so the error can persist no matter how far the bias moves (seen
        // on device: +0.2 EV residual while the bias crept from +0.08 to +1.17). After two steps in
        // one direction that don't reduce the error, hold until the scene really changes.
        if let previous = wantAtLastStep {
            let sameDirection = (want > 0) == (previous > 0)
            let sceneChanged = !sameDirection || abs(want) > abs(previous) + 0.5
            if sceneChanged {
                stalledSteps = 0
            } else if abs(want) > abs(previous) - 0.05 {
                stalledSteps += 1
            } else {
                stalledSteps = 0
            }
        }
        guard stalledSteps < 2 else { return }

        // Anti-windup: if AE already can't reach its target in this direction (at its ISO /
        // shutter limits), pushing the bias further would only overshoot later.
        let aeOffset = device.exposureTargetOffset
        if (want > 0 && aeOffset < -0.4) || (want < 0 && aeOffset > 0.4) { return }

        let step = (want * 0.4).clamped(to: -0.3...0.3)
        let newMeter = (meterBias + step).clamped(to: -2...2)
        let total = (controls.bias + newMeter).clamped(to: device.minExposureTargetBias...device.maxExposureTargetBias)
        guard (try? device.lockForConfiguration()) != nil else { return }
        device.setExposureTargetBias(total, completionHandler: nil)
        device.unlockForConfiguration()
        meterBias = newMeter
        lastMeterStep = Date()
        wantAtLastStep = want
    }

    // MARK: - Camera Control

    private func rebuildSystemControls() {
        guard session.supportsControls, let device else { return }
        for control in session.controls { session.removeControl(control) }
        apertureSlider = nil
        shutterPicker = nil
        isoPicker = nil
        focusSlider = nil

        shutterStops = ExposureMath.standardShutters.filter { caps.shutterRange.contains($0) }
        if shutterStops.isEmpty { shutterStops = [caps.shutterRange.lowerBound] }
        isoStops = ExposureMath.standardISOs.filter { caps.isoRange.contains($0) }
        if isoStops.isEmpty { isoStops = [caps.isoRange.lowerBound] }

        var added = 0
        func add(_ control: AVCaptureControl) -> Bool {
            guard added < session.maxControlsCount, session.canAddControl(control) else { return false }
            session.addControl(control)
            added += 1
            return true
        }

        for item in prefs.cameraControlItems {
            switch item {
            case .exposureBias:
                // The system slider adjusts exposureTargetBias itself; we only mirror it.
                let slider = AVCaptureSystemExposureBiasSlider(device: device) { bias in
                    Task { await self.systemBiasChanged(bias) }
                }
                _ = add(slider)

            case .aperture:
                guard caps.hasVariableAperture else { continue }
                let slider = AVCaptureSlider(String(localized: "Aperture"), symbolName: "camera.aperture", values: caps.apertureStops)
                slider.localizedValueFormat = "ƒ/%@"
                slider.setActionQueue(sessionQueue) { value in
                    Task { self.systemControlChanged(.aperture(value)) }
                }
                if add(slider) { apertureSlider = slider }

            case .shutter:
                let picker = AVCaptureIndexPicker(String(localized: "Shutter"), symbolName: "timer",
                                                  localizedIndexTitles: shutterStops.map(ExposureMath.shutterText))
                picker.setActionQueue(sessionQueue) { index in
                    Task { self.systemControlChanged(.shutter(index)) }
                }
                if add(picker) { shutterPicker = picker }

            case .iso:
                let picker = AVCaptureIndexPicker(String(localized: "ISO"), symbolName: "camera.metering.center.weighted",
                                                  localizedIndexTitles: isoStops.map { "ISO \(ExposureMath.isoText($0))" })
                picker.setActionQueue(sessionQueue) { index in
                    Task { self.systemControlChanged(.iso(index)) }
                }
                if add(picker) { isoPicker = picker }

            case .focus:
                guard caps.manualFocus else { continue }
                let slider = AVCaptureSlider(String(localized: "Focus"), symbolName: "scope", in: 0...1, step: 0.01)
                slider.setActionQueue(sessionQueue) { value in
                    Task { self.systemControlChanged(.focus(value)) }
                }
                if add(slider) { focusSlider = slider }
            }
        }
        syncSystemControls()
    }

    /// Push current values into the Camera Control widgets. Runs on sessionQueue,
    /// which is their action queue, as the SDK requires.
    private func syncSystemControls() {
        guard let device else { return }
        if let slider = apertureSlider, !caps.apertureStops.isEmpty {
            let current = controls.aperture ?? device.lensAperture
            slider.value = caps.apertureStops[ExposureMath.nearestIndex(of: current, in: caps.apertureStops)]
        }
        if let picker = shutterPicker, !shutterStops.isEmpty {
            picker.selectedIndex = ExposureMath.nearestIndex(of: controls.shutter ?? device.exposureDuration.seconds, in: shutterStops)
        }
        if let picker = isoPicker, !isoStops.isEmpty {
            picker.selectedIndex = ExposureMath.nearestIndex(of: controls.iso ?? device.iso, in: isoStops)
        }
        if let slider = focusSlider {
            slider.value = ((controls.focus ?? device.lensPosition) * 100).rounded() / 100
        }
    }

    private enum SystemChange: Sendable {
        case aperture(Float), shutter(Int), iso(Int), focus(Float)
    }

    private func systemControlChanged(_ change: SystemChange) {
        var next = controls
        switch change {
        case .aperture(let value): next.aperture = value
        case .shutter(let index):
            guard shutterStops.indices.contains(index) else { return }
            next.shutter = shutterStops[index]
        case .iso(let index):
            guard isoStops.indices.contains(index) else { return }
            next.iso = isoStops[index]
        case .focus(let value): next.focus = value
        }
        controls = sanitized(next, promoteFrom: controls)
        applyControls()
        sink.yield(.controls(controls))
    }

    private func systemBiasChanged(_ bias: Float) {
        // The system slider shows the device's total bias; the user's share excludes the meter's.
        controls.bias = bias - meterBias
        applied?.bias = bias   // the system slider already applied it to the device
        sink.yield(.controls(controls))
    }

    // MARK: - Live readouts

    private func startReadouts() {
        readoutTask?.cancel()
        readoutTask = Task {
            while !Task.isCancelled {
                self.publishReadout()
                try? await Task.sleep(for: .milliseconds(66))
            }
        }
    }

    private func publishReadout() {
        guard let device, isActive else { return }
        var r = LiveReadout()
        r.aperture = device.lensAperture
        r.shutter = device.exposureDuration.seconds
        r.iso = device.iso
        r.lensPosition = device.lensPosition
        // With TrueShot metering, show its own reading (+ = over), which also works as a light meter in manual.
        r.meterOffset = prefs.meterMode == .system ? device.exposureTargetOffset : -(meterReading ?? 0)
        r.isInterrupted = session.isInterrupted

        let gains = device.deviceWhiteBalanceGains
        let maxGain = device.maxWhiteBalanceGain
        if (1...maxGain).contains(gains.redGain), (1...maxGain).contains(gains.greenGain), (1...maxGain).contains(gains.blueGain) {
            let tt = device.temperatureAndTintValues(for: gains)
            r.temperature = tt.temperature
            r.tint = tt.tint
        }
        sink.yield(.readout(r))

        // Recover from a media-services reset / runtime error (not from an interruption).
        if isConfigured, !session.isRunning, !session.isInterrupted,
           Date().timeIntervalSince(lastRestartAttempt) > 2 {
            lastRestartAttempt = Date()
            session.startRunning()
        }
    }

    // MARK: - Capture

    private func capture(rotationAngle: CGFloat, filter: FilterSelection?, grain: GrainSettings,
                         watermark: WatermarkSettings) async {
        guard let rawType = photoOutput.availableRawPhotoPixelFormatTypes.first(where: { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) }) else {
            sink.yield(.message(String(localized: "RAW capture isn't available on this lens.")))
            return
        }

        // The photo pipeline's own flash replaces the exposure with its choice (verified on device:
        // 1/60 ISO 800 locked → 1/6 ISO 100 captured). So the flash LED is driven as a short torch
        // burst with TTL from TrueShot's meter, and the capture is a normal one that honours the
        // exposure. If that capture fails, it falls back to Apple's flash once (see below).
        var ledUsed = false
        var wanted: (seconds: Double, iso: Float)?
        if prefs.flash != .off, let device {
            if device.hasTorch, device.isTorchAvailable {
                if prefs.flash != .auto || Self.isDim(device) {
                    wanted = await fireLED(on: device)
                    ledUsed = true
                }
            } else {
                sink.yield(.message(String(localized: "Flash isn't available right now on this lens.")))
            }
        }

        var outcome = await shoot(makeSettings(rawType: rawType, rotationAngle: rotationAngle, appleFlash: false))
        if ledUsed { releaseLED() }

        // Fallback: Apple's flash. Its exposure is iOS's choice, so the HEIC is developed back to the
        // exposure TrueShot wanted; the DNG keeps what iOS captured.
        var exposureCorrection: Float = 0
        if case .failure = outcome, ledUsed, photoOutput.supportedFlashModes.contains(.on) {
            outcome = await shoot(makeSettings(rawType: rawType, rotationAngle: rotationAngle, appleFlash: true))
            if case .success(let photo) = outcome, let wanted,
               let t = photo.result.exposureTime, let iso = photo.result.iso, t > 0, iso > 0 {
                exposureCorrection = Float(log2((wanted.seconds * Double(wanted.iso)) / (t * iso))).clamped(to: -4...2)
            }
            sink.yield(.message(String(localized: "The LED flash failed, so the standard flash was used.")))
        }

        switch outcome {
        case .failure(let error):
            sink.yield(.message(error.localizedDescription))
        case .success(let photo):
            var result = photo.result
            result.flashFired = prefs.flash == .off ? nil : ledUsed
            let info = PhotoInfo(dng: photo.dng)
            result.info = info
            let pending = PendingCapture(dng: photo.dng, result: result, filter: filter, grain: grain,
                                         exposureCorrection: exposureCorrection)
            if watermark.isActive, prefs.reviewWatermark, prefs.saveFilteredCopy {
                // Nothing is saved yet: the review sheet settles the watermark, then calls finish.
                sink.yield(.review(pending))
            } else {
                await finish(pending, watermark: watermark)
            }
        }
    }

    private func makeSettings(rawType: OSType, rotationAngle: CGFloat, appleFlash: Bool) -> AVCapturePhotoSettings {
        let settings = AVCapturePhotoSettings(rawPixelFormatType: rawType)
        settings.photoQualityPrioritization = .speed
        if appleFlash { settings.flashMode = .on }     // caller checked supportedFlashModes
        if prefs.embedDNGPreview, let codec = settings.availableRawEmbeddedThumbnailPhotoCodecTypes.first {
            settings.rawEmbeddedThumbnailPhotoFormat = [AVVideoCodecKey: codec]
        }
        if let previewType = settings.availablePreviewPhotoPixelFormatTypes.first {
            settings.previewPhotoFormat = [
                kCVPixelBufferPixelFormatTypeKey as String: previewType,
                kCVPixelBufferWidthKey as String: 640,
                kCVPixelBufferHeightKey as String: 640,
            ]
        }
        if let connection = photoOutput.connection(with: .video),
           connection.isVideoRotationAngleSupported(rotationAngle) {
            connection.videoRotationAngle = rotationAngle
        }
        return settings
    }

    private func shoot(_ settings: AVCapturePhotoSettings) async -> Result<CapturedPhoto, CameraError> {
        let id = settings.uniqueID
        let sink = self.sink
        let outcome: Result<CapturedPhoto, CameraError> = await withCheckedContinuation { continuation in
            let processor = PhotoCaptureProcessor(willCapture: { sink.yield(.willCapture) }) { result in
                continuation.resume(returning: result)
            }
            inFlight[id] = processor
            photoOutput.capturePhoto(with: settings, delegate: processor)
        }
        inFlight[id] = nil
        return outcome
    }

    /// Develop (when a look or watermark is set), save to Photos, and report the result.
    func finish(_ pending: PendingCapture, watermark: WatermarkSettings) async {
        let filter = pending.filter, grain = pending.grain
        var result = pending.result
        var heic: Data?
        let corrected = abs(pending.exposureCorrection) > 0.3
        if filter != nil || grain.isActive || watermark.isActive || corrected, prefs.saveFilteredCopy {
            let dng = pending.dng
            heic = await Task.detached(priority: .userInitiated) { () -> Data? in
                var cube: CubeLUT?
                if let filter {
                    guard let loaded = LUTLibrary.shared.cube(for: filter.id) else { return nil }
                    cube = loaded
                }
                return try? FilteredDeveloper.develop(dng: dng, cube: cube, intensity: filter?.intensity ?? 1,
                                                      grain: grain, watermark: watermark,
                                                      exposure: pending.exposureCorrection)
            }.value
            if heic == nil {
                sink.yield(.message(String(localized: "The filtered copy couldn't be made. The RAW was still saved.")))
            } else {
                var parts: [String] = []
                if let info = filter.flatMap({ LUTLibrary.shared.info($0.id) }) { parts.append("\(info.brand) · \(info.name)") }
                if grain.isActive { parts.append(String(localized: "Grain \(Int((grain.amount * 100).rounded()))%")) }
                if watermark.isActive { parts.append(String(localized: "\(watermark.style.label) watermark")) }
                result.filterName = parts.joined(separator: " + ")
            }
        }
        if let heic { result.processed = Self.previewImage(from: heic) }
        if watermark.isActive, heic != nil {
            let dng = pending.dng, exposure = pending.exposureCorrection
            result.clean = await Task.detached(priority: .utility) { () -> UIImage? in
                let cube = filter.flatMap { LUTLibrary.shared.cube(for: $0.id) }
                return FilteredDeveloper.previewBase(dng: dng, cube: cube, intensity: filter?.intensity ?? 1,
                                                     grain: grain, exposure: exposure).map { UIImage(cgImage: $0) }
            }.value
        } else {
            result.clean = result.processed
        }
        switch await Self.saveToLibrary(dng: pending.dng, heic: heic) {
        case .saved:
            result.saved = true
        case .savedSeparately(let pairError):
            result.saved = true
            sink.yield(.message(String(localized: "Saved RAW and HEIC as separate photos (pairing failed: \(pairError)).")))
        case .notAuthorized:
            sink.yield(.message(String(localized: "Couldn't save: allow TrueShot to add photos in Settings › Privacy › Photos.")))
        case .failed(let error):
            sink.yield(.message(String(localized: "Couldn't save to Photos (\(error)).")))
        }
        sink.yield(.captured(result))
    }

    /// A display-sized, upright preview of the saved HEIC.
    private static func previewImage(from heic: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(heic as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 1600,
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    enum SaveOutcome: Sendable {
        case saved, savedSeparately(String), notAuthorized, failed(String)
    }

    /// With a filtered copy, the HEIC is the asset's photo and the DNG its RAW alternate,
    /// so Photos shows the look and keeps the untouched RAW alongside it. If Photos rejects
    /// the pair, both files are still saved, as separate photos, and the reason is reported.
    private static func saveToLibrary(dng: Data, heic: Data?) async -> SaveOutcome {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return .notAuthorized }
        let stamp = Int(Date().timeIntervalSince1970)

        guard let heic else {
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetCreationRequest.forAsset()
                        .addResource(with: .photo, data: dng, options: options("com.adobe.raw-image", "TrueShot_\(stamp).DNG"))
                }
                return .saved
            } catch {
                print("TrueShot: DNG save failed: \(describe(error)) — \(error)")
                return .failed(describe(error))
            }
        }

        // Paired the way Apple's RAW sample does it: processed photo as data with no options,
        // the DNG as a file Photos moves in. (Passing the DNG as data with a UTI and filename
        // fails with PHPhotosError 3300 "change not supported as configured" — verified on device.)
        let rawURL = FileManager.default.temporaryDirectory.appending(path: "TrueShot_\(stamp).dng")
        do {
            try dng.write(to: rawURL)
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: heic, options: nil)
                let rawOptions = PHAssetResourceCreationOptions()
                rawOptions.shouldMoveFile = true
                request.addResource(with: .alternatePhoto, fileURL: rawURL, options: rawOptions)
            }
            return .saved
        } catch {
            try? FileManager.default.removeItem(at: rawURL)
            let reason = describe(error)
            print("TrueShot: HEIC+DNG pair failed: \(reason) — \(error)")
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetCreationRequest.forAsset()
                        .addResource(with: .photo, data: dng, options: options("com.adobe.raw-image", "TrueShot_\(stamp).DNG"))
                    PHAssetCreationRequest.forAsset()
                        .addResource(with: .photo, data: heic, options: options("public.heic", "TrueShot_\(stamp).HEIC"))
                }
                return .savedSeparately(reason)
            } catch {
                print("TrueShot: separate save failed too: \(describe(error)) — \(error)")
                return .failed(describe(error))
            }
        }
    }

    private static func options(_ uti: String, _ filename: String) -> PHAssetResourceCreationOptions {
        let o = PHAssetResourceCreationOptions()
        o.uniformTypeIdentifier = uti
        o.originalFilename = filename
        return o
    }

    private static func describe(_ error: any Error) -> String {
        let e = error as NSError
        let domain = e.domain == PHPhotosErrorDomain ? "Photos" : e.domain
        return "\(domain) \(e.code)"
    }
}

enum CameraError: LocalizedError, Sendable {
    case noCamera, cannotAddInput, cannotAddOutput, captureFailed(String), noData

    var errorDescription: String? {
        switch self {
        case .noCamera: String(localized: "No back camera was found.")
        case .cannotAddInput: String(localized: "The camera couldn't be opened.")
        case .cannotAddOutput: String(localized: "Photo capture couldn't be configured.")
        case .captureFailed(let reason): String(localized: "Capture failed: \(reason)")
        case .noData: String(localized: "The camera returned no RAW data.")
        }
    }
}

/// Receives Camera Control lifecycle callbacks on sessionQueue.
final class SessionControlsDelegate: NSObject, AVCaptureSessionControlsDelegate, Sendable {
    private let onFullscreen: @Sendable (Bool) -> Void

    init(onFullscreen: @escaping @Sendable (Bool) -> Void) {
        self.onFullscreen = onFullscreen
    }

    func sessionControlsDidBecomeActive(_ session: AVCaptureSession) {}
    func sessionControlsWillEnterFullscreenAppearance(_ session: AVCaptureSession) { onFullscreen(true) }
    func sessionControlsWillExitFullscreenAppearance(_ session: AVCaptureSession) { onFullscreen(false) }
    func sessionControlsDidBecomeInactive(_ session: AVCaptureSession) { onFullscreen(false) }
}

extension CMTime {
    func clamped(to range: ClosedRange<CMTime>) -> CMTime {
        if self < range.lowerBound { return range.lowerBound }
        if self > range.upperBound { return range.upperBound }
        return self
    }
}
