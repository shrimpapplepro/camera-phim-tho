import Foundation

/// Every user-facing setting. Persisted as JSON in UserDefaults.
struct Preferences: Codable, Equatable, Sendable {
    enum StepSize: String, Codable, CaseIterable, Identifiable, Sendable {
        case tenth, third, half, full
        var id: String { rawValue }
        /// Step in EV (stops of light).
        var ev: Double {
            switch self {
            case .tenth: 0.1
            case .third: 1.0 / 3.0
            case .half: 0.5
            case .full: 1.0
            }
        }
        var label: String {
            switch self {
            case .tenth: String(localized: "1/10 Stop (Fine)")
            case .third: String(localized: "1/3 Stop")
            case .half: String(localized: "1/2 Stop")
            case .full: String(localized: "Full Stop")
            }
        }
    }

    enum Flash: String, Codable, CaseIterable, Identifiable, Sendable {
        case off, auto, on, pointAndShoot
        var id: String { rawValue }
        var label: String {
            switch self {
            case .off: String(localized: "Off")
            case .auto: String(localized: "Auto")
            case .on: String(localized: "On")
            case .pointAndShoot: String(localized: "Point & Shoot")
            }
        }
        var symbol: String {
            switch self {
            case .off: "bolt.slash.fill"
            case .auto: "bolt.badge.automatic.fill"
            case .on: "bolt.fill"
            case .pointAndShoot: "bolt.circle.fill"
            }
        }
        /// Point & Shoot: auto exposure may not pick a shutter slower than this, to freeze the subject
        /// (the LED-lit subject is metered; the unlit background falls dark on its own).
        static let pointAndShootSlowestShutter: Double = 1.0 / 60
    }

    enum Grid: String, Codable, CaseIterable, Identifiable, Sendable {
        case off, thirds, quarters, center
        var id: String { rawValue }
        var label: String {
            switch self {
            case .off: String(localized: "Off")
            case .thirds: String(localized: "Rule of Thirds")
            case .quarters: String(localized: "4 × 4")
            case .center: String(localized: "Center Cross")
            }
        }
    }

    enum ApertureSpeed: String, Codable, CaseIterable, Identifiable, Sendable {
        case system, slow, medium, fast
        var id: String { rawValue }
        /// `autoExposureLensApertureRateLimit`: 0 = system chooses; otherwise ≥ 1.0 (area ratio per frame).
        var rateLimit: Float {
            switch self {
            case .system: 0
            case .slow: 1.03
            case .medium: 1.1
            case .fast: 1.3
            }
        }
        var label: String {
            switch self {
            case .system: String(localized: "Automatic")
            case .slow: String(localized: "Slow")
            case .medium: String(localized: "Medium")
            case .fast: String(localized: "Fast")
            }
        }
    }

    enum CameraControlItem: String, Codable, CaseIterable, Identifiable, Sendable {
        case exposureBias, aperture, shutter, iso, focus
        var id: String { rawValue }
        var label: String {
            switch self {
            case .exposureBias: String(localized: "Exposure")
            case .aperture: String(localized: "Aperture")
            case .shutter: String(localized: "Shutter")
            case .iso: String(localized: "ISO")
            case .focus: String(localized: "Focus")
            }
        }
    }

    // Metering
    var meterMode: MeterMode = .balanced

    // Flash
    var flash: Flash = .off

    // Adjustment
    var stepSize: StepSize = .tenth
    var snapApertureToStops = false
    var dialSensitivity: Double = 1.0
    var haptics = true

    // Display
    var grid: Grid = .thirds
    var showMeter = true
    var showFocusReticle = true

    // Capture
    var embedDNGPreview = true
    var captureWithVolumeButtons = true
    var rememberControls = false

    // Auto exposure (iOS 27)
    var faceDrivenAutoExposure = true
    var automaticExposureSignals = true
    var enabledExposureSignals: [String] = []
    var apertureSpeed: ApertureSpeed = .system

    // Filters
    var saveFilteredCopy = true
    var filter: FilterSelection?
    var grain = GrainSettings()
    var watermark = WatermarkSettings()
    var reviewWatermark = true

    // Camera Control button
    var cameraControlItems: [CameraControlItem] = [.exposureBias, .aperture, .shutter, .iso]

    init() {}

    // Tolerant decoding: a missing or renamed key falls back to its default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Preferences()
        meterMode = (try? c.decode(MeterMode.self, forKey: .meterMode)) ?? d.meterMode
        flash = (try? c.decode(Flash.self, forKey: .flash)) ?? d.flash
        stepSize = (try? c.decode(StepSize.self, forKey: .stepSize)) ?? d.stepSize
        snapApertureToStops = (try? c.decode(Bool.self, forKey: .snapApertureToStops)) ?? d.snapApertureToStops
        dialSensitivity = (try? c.decode(Double.self, forKey: .dialSensitivity)) ?? d.dialSensitivity
        haptics = (try? c.decode(Bool.self, forKey: .haptics)) ?? d.haptics
        grid = (try? c.decode(Grid.self, forKey: .grid)) ?? d.grid
        showMeter = (try? c.decode(Bool.self, forKey: .showMeter)) ?? d.showMeter
        showFocusReticle = (try? c.decode(Bool.self, forKey: .showFocusReticle)) ?? d.showFocusReticle
        embedDNGPreview = (try? c.decode(Bool.self, forKey: .embedDNGPreview)) ?? d.embedDNGPreview
        captureWithVolumeButtons = (try? c.decode(Bool.self, forKey: .captureWithVolumeButtons)) ?? d.captureWithVolumeButtons
        rememberControls = (try? c.decode(Bool.self, forKey: .rememberControls)) ?? d.rememberControls
        faceDrivenAutoExposure = (try? c.decode(Bool.self, forKey: .faceDrivenAutoExposure)) ?? d.faceDrivenAutoExposure
        automaticExposureSignals = (try? c.decode(Bool.self, forKey: .automaticExposureSignals)) ?? d.automaticExposureSignals
        enabledExposureSignals = (try? c.decode([String].self, forKey: .enabledExposureSignals)) ?? d.enabledExposureSignals
        apertureSpeed = (try? c.decode(ApertureSpeed.self, forKey: .apertureSpeed)) ?? d.apertureSpeed
        cameraControlItems = (try? c.decode([CameraControlItem].self, forKey: .cameraControlItems)) ?? d.cameraControlItems
        saveFilteredCopy = (try? c.decode(Bool.self, forKey: .saveFilteredCopy)) ?? d.saveFilteredCopy
        filter = try? c.decodeIfPresent(FilterSelection.self, forKey: .filter)
        grain = (try? c.decode(GrainSettings.self, forKey: .grain)) ?? d.grain
        watermark = (try? c.decode(WatermarkSettings.self, forKey: .watermark)) ?? d.watermark
        reviewWatermark = (try? c.decode(Bool.self, forKey: .reviewWatermark)) ?? d.reviewWatermark
    }

    private static let key = "TrueShot.preferences.v1"

    static func load() -> Preferences {
        guard let data = UserDefaults.standard.data(forKey: key),
              let prefs = try? JSONDecoder().decode(Preferences.self, from: data) else { return Preferences() }
        return prefs
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    // Manual control values, stored separately because they change on every dial tick.
    private static let controlsKey = "TrueShot.controls.v1"

    static func loadControls() -> ControlState? {
        guard let data = UserDefaults.standard.data(forKey: controlsKey) else { return nil }
        return try? JSONDecoder().decode(ControlState.self, from: data)
    }

    static func saveControls(_ controls: ControlState?) {
        if let controls, let data = try? JSONEncoder().encode(controls) {
            UserDefaults.standard.set(data, forKey: controlsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: controlsKey)
        }
    }
}
