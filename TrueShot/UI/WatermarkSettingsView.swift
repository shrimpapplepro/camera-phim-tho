import CoreImage
import SwiftUI

/// Watermark defaults in Settings, with a live preview rendered by the same code that
/// stamps the saved HEIC.
struct WatermarkSettingsView: View {
    @Bindable var model: CameraModel
    @State private var preview: UIImage?

    private var settings: WatermarkSettings { model.preferences.watermark }

    var body: some View {
        Form {
            Section {
                WatermarkPreview(image: preview)
            } footer: {
                Text(model.lastCapture?.info == nil
                     ? "Sample values shown. Your photos use their own metadata: camera model, lens, and the aperture, shutter and ISO actually used."
                     : "Shown with your last photo and its metadata.")
            }

            WatermarkFields(settings: $model.preferences.watermark)

            if settings.isActive {
                Section {
                    Toggle("Review Before Saving", isOn: $model.preferences.reviewWatermark)
                } footer: {
                    Text(model.preferences.reviewWatermark
                         ? "After each shot, adjust the watermark on the actual photo, then save. Nothing is saved until you tap Save."
                         : "Photos save immediately with these settings.")
                }
            }
        }
        .navigationTitle("Watermark")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: settings) {
            let capture = model.lastCapture
            // Never the processed image: it already carries the watermark it was saved with.
            let base = (capture?.clean ?? capture?.thumbnail).flatMap(WatermarkPreview.upright)
            preview = await WatermarkPreview.render(settings, info: capture?.info ?? .sample, base: base)
        }
    }
}

/// Style, fields and signature. Shared by Settings and the post-capture review sheet.
struct WatermarkFields: View {
    @Binding var settings: WatermarkSettings

    var body: some View {
        Section("Style") {
            Picker("Style", selection: $settings.style) {
                ForEach(WatermarkSettings.Style.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        if settings.style == .dateStamp {
            Section {
            } footer: {
                Text("The orange date of compact film cameras, from the photo's capture time. Only the HEIC is stamped.")
            }
        } else if settings.isActive {
            Section {
                Toggle("Camera Model", isOn: $settings.showModel)
                Toggle("Lens", isOn: $settings.showLens)
                Toggle("Exposure", isOn: $settings.showExposure)
                Toggle("Date & Time", isOn: $settings.showDate)
                TextField("Signature (optional)", text: $settings.signature)
                    .textInputAutocapitalization(.words)
            } header: {
                Text("Show")
            } footer: {
                Text("Only the HEIC is watermarked. The DNG is saved untouched.")
            }
        }
    }
}

struct WatermarkPreview: View {
    let image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(.black)
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                ProgressView()
            }
        }
        .frame(height: 340)
        .listRowInsets(EdgeInsets())
        .accessibilityLabel("Watermark preview")
    }

    /// Renders `settings` over `base` (upright) off the main thread.
    static func render(_ settings: WatermarkSettings, info: PhotoInfo, base: CIImage?) async -> UIImage? {
        await Task.detached(priority: .userInitiated) { () -> UIImage? in
            let source = base ?? CIImage(color: CIColor(red: 0.42, green: 0.45, blue: 0.5))
                .cropped(to: CGRect(x: 0, y: 0, width: 900, height: 1200))
            let framed = Watermark.apply(settings, info: info, to: source)
            guard let cg = context.createCGImage(framed, from: framed.extent) else { return nil }
            return UIImage(cgImage: cg)
        }.value
    }

    private nonisolated static let context = CIContext()   // CIContext is thread-safe

    static func upright(_ image: UIImage) -> CIImage? {
        guard let cg = image.cgImage else { return nil }
        let orientation: CGImagePropertyOrientation = switch image.imageOrientation {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        case .upMirrored: .upMirrored
        case .downMirrored: .downMirrored
        case .leftMirrored: .leftMirrored
        case .rightMirrored: .rightMirrored
        @unknown default: .up
        }
        let ci = CIImage(cgImage: cg).oriented(orientation)
        return ci.transformed(by: CGAffineTransform(translationX: -ci.extent.minX, y: -ci.extent.minY))
    }
}

extension PhotoInfo {
    /// Placeholder values for the Settings preview before any photo has been taken.
    static var sample: PhotoInfo {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return PhotoInfo(make: "Apple", model: "iPhone", lensModel: "iPhone back camera 6.86mm f/1.78",
                         focalLength: 6.86, focalLength35: 24, fNumber: 1.8, exposureTime: 1.0 / 120,
                         iso: 100, dateOriginal: f.string(from: Date()))
    }
}
