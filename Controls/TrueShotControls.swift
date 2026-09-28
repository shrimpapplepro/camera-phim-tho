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
                Label("Phim Thô", image: "trueshot.aperture")
            }
        }
        .displayName("Phim Thô")
        .description("Open Phim Thô's RAW camera.")
    }
}
