@preconcurrency import AVFoundation
import SwiftUI

struct SettingsView: View {
    @Bindable var model: CameraModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmReset = false

    private var caps: CameraCapabilities { model.capabilities }

    var body: some View {
        NavigationStack {
            Form {
                meteringSection
                adjustmentSection
                viewfinderSection
                captureSection
                filterSection
                autoExposureSection
                cameraControlSection
                lensSection
                resetSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Reset all settings?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Reset Settings", role: .destructive) {
                    model.preferences = Preferences()
                    model.resetAllToAuto()
                }
            } message: {
                Text("All preferences return to their defaults and every control returns to Auto.")
            }
        }
    }

    // MARK: Sections

    private var meteringSection: some View {
        Section {
            Picker("Metering", selection: $model.preferences.meterMode) {
                ForEach(MeterMode.allCases) { Text($0.label).tag($0) }
            }
        } header: {
            Text("Metering")
        } footer: {
            Text(model.preferences.meterMode.detail + " Your exposure compensation is applied on top.")
        }
    }

    private var adjustmentSection: some View {
        Section {
            Picker("Step Size", selection: $model.preferences.stepSize) {
                ForEach(Preferences.StepSize.allCases) { Text($0.label).tag($0) }
            }
            VStack(alignment: .leading) {
                LabeledContent("Dial Speed", value: model.preferences.dialSensitivity.formatted(.number.precision(.fractionLength(1))) + "×")
                Slider(value: $model.preferences.dialSensitivity, in: 0.5...2, step: 0.1) {
                    Text("Dial Speed")
                } minimumValueLabel: {
                    Image(systemName: "tortoise")
                } maximumValueLabel: {
                    Image(systemName: "hare")
                }
            }
            if caps.hasVariableAperture {
                Toggle("Snap Aperture to Lens Stops", isOn: $model.preferences.snapApertureToStops)
            }
            Toggle("Haptic Feedback", isOn: $model.preferences.haptics)
        } header: {
            Text("Manual Adjustment")
        } footer: {
            Text("Aperture, shutter, ISO and exposure dials move in stops of light, so one step is the same brightness change on every dial. White balance and focus use their own fine steps when 1/10 Stop is selected.")
        }
    }

    private var viewfinderSection: some View {
        Section("Viewfinder") {
            Picker("Grid", selection: $model.preferences.grid) {
                ForEach(Preferences.Grid.allCases) { Text($0.label).tag($0) }
            }
            Toggle("Exposure Meter", isOn: $model.preferences.showMeter)
            Toggle("Focus Indicator", isOn: $model.preferences.showFocusReticle)
        }
    }

    private var captureSection: some View {
        Section {
            LabeledContent("Format", value: "Bayer RAW (DNG)")
            LabeledContent("Processing", value: String(localized: "None"))
            Toggle("Embed Preview in DNG", isOn: $model.preferences.embedDNGPreview)
            Toggle("Volume Buttons & Camera Control Capture", isOn: $model.preferences.captureWithVolumeButtons)
            Toggle("Remember Manual Settings", isOn: $model.preferences.rememberControls)
        } header: {
            Text("Capture")
        } footer: {
            Text("Photos are saved as unprocessed Bayer RAW: no Deep Fusion, Smart HDR, Night mode, noise reduction, sharpening or tone mapping, and no digital zoom. Color and tone are set when the DNG is developed. The embedded preview is only a thumbnail for viewers; it doesn't change the RAW data.")
        }
    }

    private var filterSection: some View {
        Section {
            Toggle("Save Filtered Copy", isOn: $model.preferences.saveFilteredCopy)
            NavigationLink {
                WatermarkSettingsView(model: model)
            } label: {
                LabeledContent("Watermark", value: model.preferences.watermark.style.label)
            }
            LabeledContent("Library", value: "\(model.library.catalog.count) looks · \(model.library.brands.count) brands")
        } header: {
            Text("Filters")
        } footer: {
            Text("With a filter, grain or watermark on, TrueShot develops the RAW (no noise reduction or sharpening), applies them and saves a HEIC, with the untouched DNG attached as its RAW original. Turn this off to use looks only in the viewfinder (watermarks need it on).")
        }
    }

    @ViewBuilder
    private var autoExposureSection: some View {
        Section {
            Toggle("Face-Priority Metering", isOn: $model.preferences.faceDrivenAutoExposure)
            if !caps.supportedExposureSignals.isEmpty {
                Toggle("Automatic Scene Signals", isOn: $model.preferences.automaticExposureSignals)
                if !model.preferences.automaticExposureSignals {
                    ForEach(caps.supportedExposureSignals, id: \.self) { raw in
                        Toggle(ExposureSignalInfo.name(raw), isOn: signalBinding(raw))
                    }
                }
            }
            if caps.hasVariableAperture {
                Picker("Auto Aperture Speed", selection: $model.preferences.apertureSpeed) {
                    ForEach(Preferences.ApertureSpeed.allCases) { Text($0.label).tag($0) }
                }
            }
        } header: {
            Text("Auto Exposure")
        } footer: {
            Text("Scene signals let auto exposure close or open the aperture for motion, groups, documents, point lights and flicker. Turn off Automatic to choose them yourself. These only apply to parameters left on Auto.")
        }
    }

    private var cameraControlSection: some View {
        Section {
            ForEach(Preferences.CameraControlItem.allCases) { item in
                Toggle(item.label, isOn: cameraControlBinding(item))
                    .disabled(!isCameraControlItemAvailable(item))
            }
        } header: {
            Text("Camera Control")
        } footer: {
            Text("Controls available from the Camera Control button. A light double-press opens the list. Aperture appears only on a lens with a variable aperture.")
        }
    }

    private var lensSection: some View {
        Section {
            if let lens = model.lenses.first(where: { $0.id == model.lensID }) {
                LabeledContent("Lens", value: "\(lens.label) · \(lens.name)")
            }
            LabeledContent("Aperture", value: apertureDescription)
            if caps.hasVariableAperture {
                LabeledContent("Lens Stops", value: caps.apertureStops.map { String(format: "%.1f", $0) }.joined(separator: " · "))
            }
            LabeledContent("Shutter", value: "\(ExposureMath.shutterText(caps.shutterRange.lowerBound)) – \(ExposureMath.shutterText(caps.shutterRange.upperBound))")
            LabeledContent("ISO", value: "\(ExposureMath.isoText(caps.isoRange.lowerBound)) – \(ExposureMath.isoText(caps.isoRange.upperBound))")
            LabeledContent("Bayer RAW", value: caps.rawAvailable ? String(localized: "Available") : String(localized: "Unavailable"))
            LabeledContent("Manual Focus", value: caps.manualFocus ? String(localized: "Yes") : String(localized: "No"))
            LabeledContent("Manual White Balance", value: caps.manualWhiteBalance ? String(localized: "Yes") : String(localized: "No"))
            NavigationLink("Supported Exposure Modes") {
                ExposureModesView(capabilities: caps)
            }
        } header: {
            Text("Current Lens")
        } footer: {
            Text("Read from the camera hardware at runtime.")
        }
    }

    private var resetSection: some View {
        Section {
            Button("Reset All Settings", role: .destructive) { confirmReset = true }
        }
    }

    // MARK: Helpers

    private var apertureDescription: String {
        if caps.hasVariableAperture {
            return "\(ExposureMath.apertureText(caps.apertureRange.lowerBound)) – \(ExposureMath.apertureText(caps.apertureRange.upperBound))"
        }
        return String(localized: "Fixed \(ExposureMath.apertureText(caps.apertureStops.first ?? 0))")
    }

    private func signalBinding(_ raw: String) -> Binding<Bool> {
        Binding {
            model.preferences.enabledExposureSignals.contains(raw)
        } set: { on in
            var set = model.preferences.enabledExposureSignals.filter { $0 != raw }
            if on { set.append(raw) }
            model.preferences.enabledExposureSignals = set
        }
    }

    private func cameraControlBinding(_ item: Preferences.CameraControlItem) -> Binding<Bool> {
        Binding {
            model.preferences.cameraControlItems.contains(item)
        } set: { on in
            // Keep the canonical order so the Camera Control list is stable.
            var items = Set(model.preferences.cameraControlItems)
            if on { items.insert(item) } else { items.remove(item) }
            model.preferences.cameraControlItems = Preferences.CameraControlItem.allCases.filter(items.contains)
        }
    }

    private func isCameraControlItemAvailable(_ item: Preferences.CameraControlItem) -> Bool {
        switch item {
        case .aperture: caps.hasVariableAperture
        case .focus: caps.manualFocus
        default: true
        }
    }
}

/// Lists which Auto/Manual combinations the current lens accepts.
struct ExposureModesView: View {
    let capabilities: CameraCapabilities

    var body: some View {
        List {
            Section {
                ForEach(rows, id: \.mask) { row in
                    LabeledContent(row.name) {
                        Image(systemName: row.supported ? "checkmark.circle.fill" : "xmark.circle")
                            .foregroundStyle(row.supported ? .green : .secondary)
                            .accessibilityLabel(row.supported ? "Supported" : "Not supported")
                    }
                }
            } footer: {
                Text("When you choose a combination that isn't supported, TrueShot locks the remaining settings at their current values, making it fully manual.")
            }
        }
        .navigationTitle("Exposure Modes")
    }

    private var rows: [(mask: UInt8, name: String, supported: Bool)] {
        let masks: [UInt8] = capabilities.hasVariableAperture ? [0, 1, 2, 4, 3, 5, 6, 7] : [0, 2, 4, 6]
        return masks.map { ($0, Self.name($0, variable: capabilities.hasVariableAperture), capabilities.supportedCombos.contains($0)) }
    }

    static func name(_ mask: UInt8, variable: Bool) -> String {
        let axes = ManualAxes(rawValue: mask)
        switch axes {
        case []: return String(localized: "Program (all Auto)")
        case [.aperture]: return String(localized: "Aperture Priority")
        case [.shutter]: return String(localized: "Shutter Priority")
        case [.iso]: return String(localized: "ISO Priority")
        case [.aperture, .shutter]: return String(localized: "Aperture + Shutter (Auto ISO)")
        case [.aperture, .iso]: return String(localized: "Aperture + ISO (Auto Shutter)")
        case [.shutter, .iso]: return variable ? String(localized: "Shutter + ISO (Auto Aperture)") : String(localized: "Full Manual")
        default: return String(localized: "Full Manual")
        }
    }
}

enum ExposureSignalInfo {
    static func name(_ raw: String) -> String {
        switch raw {
        case AVCaptureDeviceExposureSignal.subjectMotion.rawValue: String(localized: "Subject Motion")
        case AVCaptureDeviceExposureSignal.groupPhoto.rawValue: String(localized: "Group Photo")
        case AVCaptureDeviceExposureSignal.document.rawValue: String(localized: "Document")
        case AVCaptureDeviceExposureSignal.starburst.rawValue: String(localized: "Point Lights")
        case AVCaptureDeviceExposureSignal.flicker.rawValue: String(localized: "Flicker")
        default: raw
        }
    }
}
