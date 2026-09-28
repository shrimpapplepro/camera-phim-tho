import ExtensionKit
import Foundation
import LockedCameraCapture
import SwiftUI

/// TrueShot's camera on the Lock Screen: the same camera, looks and saving as the app.
@main
struct TrueShotCaptureExtension: LockedCameraCaptureExtension {
    var body: some LockedCameraCaptureExtensionScene {
        LockedCameraCaptureUIScene { session in
            LockedCameraRoot(session: session)
        }
    }
}

private struct LockedCameraRoot: View {
    let session: LockedCameraCaptureSession
    @State private var model = CameraModel()

    var body: some View {
        CameraView(model: model, openApp: openApp)
            .preferredColorScheme(.dark)
            .tint(.yellow)
            .task {
                // The app publishes its settings as the intent's app context; apply them here.
                if let context = try? await TrueShotCaptureIntent.appContext {
                    model.applyAppContext(context)
                }
            }
    }

    /// Asks for Face ID / passcode and continues in the full app.
    private func openApp() {
        Task {
            try? await session.openApplication(for: NSUserActivity(activityType: NSUserActivityTypeLockedCameraCapture))
        }
    }
}
