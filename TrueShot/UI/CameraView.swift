import AVKit
import SwiftUI

struct CameraView: View {
    let model: CameraModel
    /// Set on the Lock Screen: the settings button becomes "Open TrueShot" (unlock + open app),
    /// since settings can't be saved back from the locked camera.
    var openApp: (() -> Void)? = nil

    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false
    @State private var showLastCapture = false
    @State private var flash = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch model.status {
            case .unauthorized:
                PermissionView()
            case .failed(let reason):
                ContentUnavailableView("Camera Unavailable", systemImage: "camera.badge.ellipsis", description: Text(reason))
            case .starting, .running:
                camera
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear { model.start() }
        .onChange(of: scenePhase) { _, phase in
            model.setActive(phase == .active)
        }
        .onCameraCaptureEvent(isEnabled: model.preferences.captureWithVolumeButtons) { event in
            if event.phase == .ended { model.capture() }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(model: model)
        }
        .sheet(item: Binding(get: { model.pendingReview }, set: { if $0 == nil { model.discardReview() } })) { pending in
            ReviewView(model: model, pending: pending)
        }
        .sheet(isPresented: $showLastCapture) {
            if let capture = model.lastCapture {
                LastCaptureView(capture: capture)
            }
        }
    }

    private var camera: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 16)
                .frame(height: 52)
            viewfinder
            Spacer(minLength: 8)
            if !model.systemControlsFullscreen {
                ParameterStrip(model: model)
                    .padding(.horizontal, 12)
                    .transition(.opacity)
            }
            Spacer(minLength: 8)
            bottomBar
                .padding(.horizontal, 28)
                .padding(.bottom, 8)
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    if let openApp { openApp() } else { showSettings = true }
                } label: {
                    Image(systemName: openApp == nil ? "gearshape" : "arrow.up.forward.app")
                        .font(.body.weight(.medium))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel(openApp == nil ? "Settings" : "Open TrueShot")

                Spacer()
                statusCapsule
                Spacer()

                Button {
                    cycleGrid()
                } label: {
                    Image(systemName: model.preferences.grid == .off ? "grid" : "grid.circle.fill")
                        .font(.body.weight(.medium))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Grid")
                .accessibilityValue(model.preferences.grid.label)
            }
        }
    }

    private func cycleGrid() {
        let all = Preferences.Grid.allCases
        let i = all.firstIndex(of: model.preferences.grid) ?? 0
        model.preferences.grid = all[(i + 1) % all.count]
    }

    /// Lens buttons centred; one look button in the bottom-right corner (thumb reach). With a look
    /// active it expands to show the look's name in orange; otherwise it's just the icon.
    private var bottomControls: some View {
        ZStack {
            if model.lenses.count > 1 {
                LensPicker(model: model)
            }
            HStack {
                Spacer()
                lookButton
            }
        }
    }

    private var lookButton: some View {
        let parts = [model.filterInfo?.name, model.preferences.grain.isActive ? String(localized: "Grain") : nil]
            .compactMap { $0 }
        let name = parts.joined(separator: " + ")
        // Shortened so the capsule never reaches the centred lens buttons (~95 pt of caption text).
        let shown = name.count > 16 ? String(name.prefix(15)) + "…" : name
        return Button {
            withAnimation(.smooth(duration: 0.25)) { model.showFilters = true }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "camera.filters")
                    .font(.body.weight(.medium))
                if model.lookActive {
                    Text(shown)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(model.lookActive ? Color.orange : Color.primary)
            .padding(.horizontal, model.lookActive ? 12 : 0)
            .frame(minWidth: 44, minHeight: 44)
            .fixedSize()
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityLabel("Filters")
        .accessibilityValue(model.lookActive ? name : String(localized: "None"))
        .animation(.smooth(duration: 0.25), value: model.lookActive)
    }

    private var statusCapsule: some View {
        HStack(spacing: 8) {
            Text("RAW")
                .font(.caption.weight(.bold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(model.capabilities.rawAvailable ? Color.yellow : Color.gray, in: .rect(cornerRadius: 4))
                .foregroundStyle(.black)
            if model.preferences.showMeter {
                ExposureMeter(offset: model.readout.meterOffset)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("RAW DNG, meter \(ExposureMath.biasText(model.readout.meterOffset)) EV")
    }

    // MARK: Viewfinder

    private var viewfinder: some View {
        CameraPreview(model: model)
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .overlay { GridOverlay(style: model.preferences.grid).allowsHitTesting(false) }
            .overlay {
                if let point = model.focusReticle {
                    FocusReticle()
                        .position(point)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .overlay { Color.black.opacity(flash ? 1 : 0).allowsHitTesting(false) }
            .overlay(alignment: .top) {
                if let message = model.message {
                    Text(message)
                        .font(.footnote.weight(.medium))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .glassEffect(.regular, in: .capsule)
                        .padding(12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .overlay {
                if model.readout.isInterrupted {
                    Label("Camera Paused", systemImage: "pause.circle")
                        .padding()
                        .glassEffect(.regular, in: .capsule)
                }
            }
            .overlay(alignment: .bottom) {
                Group {
                    if model.showFilters, !model.systemControlsFullscreen {
                        FilterBrowser(model: model)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else if let parameter = model.selected, !model.systemControlsFullscreen {
                        ParameterPanel(model: model, parameter: parameter)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else {
                        bottomControls
                            .transition(.opacity)
                    }
                }
                .padding(10)
            }
            .animation(.smooth(duration: 0.25), value: model.selected)
            .animation(.smooth(duration: 0.25), value: model.showFilters)
            .onChange(of: model.captureCount) {
                flash = true
                withAnimation(.easeOut(duration: 0.25)) { flash = false }
            }
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        HStack {
            Button {
                showLastCapture = true
            } label: {
                ThumbnailView(image: model.lastCapture?.processed ?? model.lastCapture?.thumbnail)
            }
            .buttonStyle(.plain)
            .disabled(model.lastCapture == nil)
            .accessibilityLabel("Last photo")

            Spacer()
            ShutterButton(enabled: model.status == .running && model.capabilities.rawAvailable,
                          haptics: model.preferences.haptics) {
                model.capture()
            }
            Spacer()

            Button {
                model.resetAllToAuto()
            } label: {
                Text("A")
                    .font(.title3.weight(.bold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Reset everything to Auto")
        }
    }
}

// MARK: - Components

/// A row of Liquid Glass chips, one per parameter. Tap to open its dial.
struct ParameterStrip: View {
    let model: CameraModel

    var body: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(Parameter.allCases) { parameter in
                    chip(parameter)
                }
            }
        }
    }

    private func chip(_ parameter: Parameter) -> some View {
        let selected = model.selected == parameter
        let manual = !model.isAuto(parameter)
        return Button {
            model.selected = selected ? nil : parameter
        } label: {
            VStack(spacing: 3) {
                HStack(spacing: 2) {
                    Image(systemName: parameter.symbol)
                        .font(.caption2)
                    if !manual, parameter != .bias {
                        Text("A").font(.system(size: 8, weight: .heavy))
                    }
                }
                .foregroundStyle(.secondary)
                Text(value(for: parameter))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(manual ? Color.yellow : Color.primary)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.vertical, 4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .glassEffect(selected ? .regular.tint(.yellow.opacity(0.35)).interactive() : .regular.interactive(),
                     in: .rect(cornerRadius: 14))
        .disabled(!model.isAvailable(parameter) && parameter != .aperture)
        .opacity(model.isAvailable(parameter) || parameter == .aperture ? 1 : 0.4)
        .accessibilityLabel(parameter.title)
        .accessibilityValue("\(value(for: parameter)), \(manual ? "manual" : "automatic")")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func value(for parameter: Parameter) -> String {
        let c = model.controls, r = model.readout
        switch parameter {
        case .aperture: return ExposureMath.apertureText(c.aperture ?? r.aperture)
        case .shutter: return ExposureMath.shutterText(c.shutter ?? r.shutter)
        case .iso: return ExposureMath.isoText(c.iso ?? r.iso)
        case .bias: return ExposureMath.biasText(c.bias)
        case .whiteBalance: return ExposureMath.kelvinText(c.temperature ?? r.temperature)
        case .focus: return c.focus.map(ExposureMath.focusText) ?? "AF"
        }
    }
}

struct LensPicker: View {
    let model: CameraModel

    var body: some View {
        GlassEffectContainer(spacing: 4) {
            HStack(spacing: 4) {
                ForEach(model.lenses) { lens in
                    let active = lens.id == model.lensID
                    Button {
                        model.selectLens(lens.id)
                    } label: {
                        Text(lens.label)
                            .font(.footnote.weight(.semibold).monospacedDigit())
                            .foregroundStyle(active ? Color.yellow : Color.primary)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(active ? .regular.interactive() : .clear.interactive(), in: .circle)
                    .accessibilityLabel(lens.name)
                    .accessibilityAddTraits(active ? .isSelected : [])
                }
            }
        }
    }
}

struct ShutterButton: View {
    let enabled: Bool
    var haptics = true
    let action: () -> Void

    var body: some View {
        Button {
            pressCount += 1
            action()
        } label: {
            ZStack {
                Circle().stroke(.white, lineWidth: 4).frame(width: 76, height: 76)
                Circle().fill(.white).frame(width: 64, height: 64)
            }
            .frame(width: 80, height: 80)
            .contentShape(.circle)
        }
        .buttonStyle(ShutterPressStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .sensoryFeedback(.impact(weight: .medium), trigger: pressCount) { _, _ in haptics }
        .accessibilityLabel("Take Photo")
    }

    @State private var pressCount = 0
}

private struct ShutterPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

struct ThumbnailView: View {
    let image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color.white.opacity(0.08)
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(.rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.3), lineWidth: 1))
    }
}

/// A center-zero meter: how far the scene is from the exposure target, ±2 EV shown.
struct ExposureMeter: View {
    let offset: Float

    var body: some View {
        HStack(spacing: 6) {
            GeometryReader { geo in
                let clamped = CGFloat(offset.clamped(to: -2...2))
                let x = geo.size.width / 2 + clamped / 2 * (geo.size.width / 2)
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25)).frame(height: 2)
                        .frame(maxHeight: .infinity)
                    Rectangle().fill(.white).frame(width: 1, height: 8)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    Circle().fill(abs(offset) > 1 ? Color.orange : Color.yellow)
                        .frame(width: 6, height: 6)
                        .position(x: x, y: geo.size.height / 2)
                }
            }
            .frame(width: 60, height: 12)
            Text(ExposureMath.biasText(offset))
                .font(.caption.monospacedDigit())
                .frame(width: 34, alignment: .trailing)
        }
    }
}

struct GridOverlay: View {
    let style: Preferences.Grid

    var body: some View {
        Canvas { context, size in
            var path = Path()
            switch style {
            case .off:
                return
            case .thirds, .quarters:
                let n = style == .thirds ? 3 : 4
                for i in 1..<n {
                    let x = size.width * CGFloat(i) / CGFloat(n)
                    let y = size.height * CGFloat(i) / CGFloat(n)
                    path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height))
                    path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y))
                }
            case .center:
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                path.move(to: CGPoint(x: c.x - 14, y: c.y)); path.addLine(to: CGPoint(x: c.x + 14, y: c.y))
                path.move(to: CGPoint(x: c.x, y: c.y - 14)); path.addLine(to: CGPoint(x: c.x, y: c.y + 14))
            }
            context.stroke(path, with: .color(.white.opacity(0.35)), lineWidth: 0.5)
        }
    }
}

struct FocusReticle: View {
    @State private var settled = false

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .stroke(.yellow, lineWidth: 1.5)
            .frame(width: 72, height: 72)
            .scaleEffect(settled ? 1 : 1.4)
            .onAppear { withAnimation(.snappy(duration: 0.25)) { settled = true } }
    }
}

struct PermissionView: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        ContentUnavailableView {
            Label("Camera Access Needed", systemImage: "camera")
        } description: {
            Text("Allow camera access in Settings to capture RAW photos.")
        } actions: {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            .buttonStyle(.glassProminent)
        }
    }
}

struct LastCaptureView: View {
    let capture: CaptureResult
    @Environment(\.dismiss) private var dismiss
    @State private var showRAW = false

    private var shown: UIImage? {
        if showRAW || capture.processed == nil { return capture.thumbnail }
        return capture.processed
    }

    var body: some View {
        NavigationStack {
            List {
                if capture.processed != nil {
                    Picker("Version", selection: $showRAW) {
                        Text("Processed").tag(false)
                        Text("RAW").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
                if let image = shown {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(.rect(cornerRadius: 12))
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .accessibilityLabel(showRAW || capture.processed == nil ? "RAW preview" : "Processed photo")
                }
                Section {
                    LabeledContent("Format", value: capture.filterName == nil ? "Bayer RAW · DNG" : "HEIC + Bayer RAW DNG")
                    if let filter = capture.filterName { LabeledContent("Look", value: filter) }
                    if let f = capture.fNumber { LabeledContent("Aperture", value: ExposureMath.apertureText(Float(f))) }
                    if let t = capture.exposureTime { LabeledContent("Shutter", value: ExposureMath.shutterText(t)) }
                    if let iso = capture.iso { LabeledContent("ISO", value: ExposureMath.isoText(Float(iso))) }
                    if let size = capture.pixelSize, size.width > 0 {
                        LabeledContent("Dimensions", value: "\(Int(size.width)) × \(Int(size.height))")
                    }
                    LabeledContent("File Size", value: capture.byteCount.formatted(.byteCount(style: .file)))
                    LabeledContent("Saved to Photos", value: capture.saved ? String(localized: "Yes") : String(localized: "No"))
                } footer: {
                    Text(capture.filterName == nil
                         ? "The preview above is a small viewing image. The DNG contains the sensor data without fusion, HDR or noise reduction."
                         : "Processed shows the saved HEIC. RAW shows the camera's quick preview of the untouched DNG, which is attached to the same photo as its RAW original.")
                }
            }
            .navigationTitle("Last Photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
