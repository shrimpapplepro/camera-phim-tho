import CoreGraphics
import UIKit

/// A physical back camera. TrueShot never uses virtual (fused) devices, because
/// Bayer RAW requires a physical lens at 1× device zoom.
struct LensOption: Identifiable, Hashable, Sendable {
    let id: String          // AVCaptureDevice.uniqueID
    let label: String       // "0.5×", "1×", "4×"
    let name: String        // localized device name, for accessibility
}

/// Which exposure axes the user has taken manual control of.
struct ManualAxes: OptionSet, Hashable, Sendable {
    let rawValue: UInt8
    static let aperture = ManualAxes(rawValue: 1 << 0)
    static let shutter  = ManualAxes(rawValue: 1 << 1)
    static let iso      = ManualAxes(rawValue: 1 << 2)
}

/// What the current lens + format can do. Everything comes from the device at runtime;
/// nothing about the iPhone 18 Pro hardware is hard-coded.
struct CameraCapabilities: Equatable, Sendable {
    var lensID = ""
    /// Sorted recommended ƒ-stops from `AVCaptureDevice.Format.recommendedLensApertureStops`.
    var apertureStops: [Float] = []
    var apertureRange: ClosedRange<Float> = 1.8...1.8
    var hasVariableAperture = false
    var shutterRange: ClosedRange<Double> = (1.0 / 8000.0)...1.0
    var isoRange: ClosedRange<Float> = 50...3200
    var biasRange: ClosedRange<Float> = -8...8
    var manualFocus = false
    /// Closest focus distance in millimetres (-1 when the lens doesn't report it).
    var minimumFocusDistance = -1
    var manualWhiteBalance = false
    var rawAvailable = false
    var hasFlash = false
    /// Manual-axis combinations the format accepts (`supportsExposureModeCustom`).
    var supportedCombos: Set<UInt8> = [0]
    var supportedExposureSignals: [String] = []

    /// Axes that can be manual on this lens (aperture only when it is really variable).
    var adjustableAxes: ManualAxes {
        hasVariableAperture ? [.aperture, .shutter, .iso] : [.shutter, .iso]
    }
}

/// The user's intent for every control. `nil` means "Auto" for that parameter.
/// The capture service owns the authoritative copy; the UI mirrors it.
struct ControlState: Codable, Equatable, Sendable {
    var aperture: Float?
    var shutter: Double?      // seconds
    var iso: Float?
    var bias: Float = 0       // EV, used whenever any exposure axis is Auto
    var focus: Float?         // lens position 0…1, nil = continuous AF
    var temperature: Float?   // kelvin, nil = auto white balance
    var tint: Float = 0

    var manualAxes: ManualAxes {
        var axes: ManualAxes = []
        if aperture != nil { axes.insert(.aperture) }
        if shutter != nil { axes.insert(.shutter) }
        if iso != nil { axes.insert(.iso) }
        return axes
    }
}

/// Live values reported by the sensor, whether chosen by auto exposure or by the user.
struct LiveReadout: Equatable, Sendable {
    var aperture: Float = 0
    var shutter: Double = 0
    var iso: Float = 0
    var lensPosition: Float = 0
    var meterOffset: Float = 0    // exposureTargetOffset, EV
    var temperature: Float = 5500
    var tint: Float = 0
    var isInterrupted = false
}

struct CaptureResult: Sendable {
    var thumbnail: UIImage?          // from the RAW capture (unprocessed)
    var processed: UIImage?          // from the saved HEIC (look, grain, watermark)
    /// The look without any watermark — the base for watermark previews (a baked-in watermark
    /// would otherwise show under every style, even Off).
    var clean: UIImage?
    var fNumber: Double?
    var exposureTime: Double?
    var iso: Double?
    var pixelSize: CGSize?
    var byteCount = 0
    var saved = false
    var filterName: String?
    var info: PhotoInfo?
    /// Whether the flash fired for this frame (from the resolved capture settings).
    var flashFired: Bool?
    var date = Date()
}

/// A captured DNG held for watermark review; nothing is saved until the user confirms.
struct PendingCapture: Identifiable, Sendable {
    let id = UUID()
    let dng: Data
    let result: CaptureResult
    let filter: FilterSelection?
    let grain: GrainSettings
    /// EV applied when developing the HEIC (Apple-flash fallback); the DNG is never changed.
    var exposureCorrection: Float = 0
}

enum CameraEvent: Sendable {
    case configured(lenses: [LensOption], lensID: String, capabilities: CameraCapabilities, controls: ControlState)
    case controls(ControlState)
    case readout(LiveReadout)
    case willCapture
    case captured(CaptureResult)
    case review(PendingCapture)
    case message(String)
    case unauthorized
    case failed(String)
    case systemControlsFullscreen(Bool)
}

enum CameraIntent: Sendable {
    case setControls(ControlState)
    case selectLens(String)
    case pointOfInterest(CGPoint)
    case capture(rotationAngle: CGFloat, filter: FilterSelection?, grain: GrainSettings, watermark: WatermarkSettings)
    case setFilterFrames(Bool)
    case finishCapture(PendingCapture, watermark: WatermarkSettings)
    case setPreferences(Preferences)
    case setActive(Bool)
}

/// The parameters the user can adjust.
enum Parameter: String, CaseIterable, Identifiable, Sendable {
    case aperture, shutter, iso, bias, whiteBalance, focus
    var id: String { rawValue }

    var title: String {
        switch self {
        case .aperture: String(localized: "Aperture")
        case .shutter: String(localized: "Shutter")
        case .iso: String(localized: "ISO")
        case .bias: String(localized: "Exposure")
        case .whiteBalance: String(localized: "White Balance")
        case .focus: String(localized: "Focus")
        }
    }

    var symbol: String {
        switch self {
        case .aperture: "camera.aperture"
        case .shutter: "timer"
        case .iso: "camera.metering.center.weighted"
        case .bias: "plusminus.circle"
        case .whiteBalance: "thermometer.medium"
        case .focus: "scope"
        }
    }
}
