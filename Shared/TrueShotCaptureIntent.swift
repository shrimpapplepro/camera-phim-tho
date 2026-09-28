import AppIntents
import Foundation

/// Launches TrueShot's camera. Shared by the app, the Control (lock screen / Control Center /
/// Action button) and the Locked Camera Capture extension, as the system requires.
struct TrueShotCaptureIntent: CameraCaptureIntent {
    static let title: LocalizedStringResource = "Open TrueShot"
    static let description = IntentDescription("Opens TrueShot's RAW camera, even from the Lock Screen.")

    typealias AppContext = TrueShotCaptureContext

    @MainActor
    func perform() async throws -> some IntentResult {
        .result()
    }
}

/// What the app hands to the lock-screen camera. While the device is locked, the extension
/// can't read the app's preferences or shared containers — this context is the only channel.
struct TrueShotCaptureContext: Codable, Sendable {
    var preferences: Data
    var controls: Data?
}

enum AppRuntime {
    /// True inside an extension (the lock-screen camera), false in the app.
    static let isExtension = Bundle.main.bundleURL.pathExtension == "appex"
}
