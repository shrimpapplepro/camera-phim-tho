import SwiftUI

@main
struct TrueShotApp: App {
    @State private var model = CameraModel()

    var body: some Scene {
        WindowGroup {
            CameraView(model: model)
                .preferredColorScheme(.dark)
                .tint(.yellow)
        }
    }
}
