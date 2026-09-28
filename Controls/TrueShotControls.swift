import AppIntents
import SwiftUI
import WidgetKit

@main
struct TrueShotControlsBundle: WidgetBundle {
    var body: some Widget {
        TrueShotCameraControl()
    }
}

/// A camera control for the Lock Screen, Control Center and the Action button. Because its
/// action is a CameraCaptureIntent, the system offers TrueShot wherever it offers camera apps.
struct TrueShotCameraControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.thanhtu.TrueShot.camera") {
            ControlWidgetButton(action: TrueShotCaptureIntent()) {
                Label("TrueShot", image: "trueshot.aperture")
            }
        }
        .displayName("TrueShot")
        .description("Open TrueShot's RAW camera.")
    }
}
