import CoreImage
import SwiftUI

/// Shown after each shot while a watermark is on: adjust the watermark on the real photo,
/// then Save (develops full-size and saves HEIC + DNG) or Discard (saves nothing).
struct ReviewView: View {
    let model: CameraModel
    let pending: PendingCapture

    @State private var watermark: WatermarkSettings
    @State private var base: CIImage?
    @State private var preview: UIImage?
    @State private var confirmDiscard = false

    init(model: CameraModel, pending: PendingCapture) {
        self.model = model
        self.pending = pending
        _watermark = State(initialValue: model.preferences.watermark)
    }

    private var info: PhotoInfo { pending.result.info ?? PhotoInfo(dng: pending.dng) }

    private struct RenderKey: Equatable {
        let watermark: WatermarkSettings
        let baseReady: Bool
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    WatermarkPreview(image: preview)
                } footer: {
                    Text("Preview at reduced size. Save develops the full-resolution photo.")
                }
                WatermarkFields(settings: $watermark)
            }
            .navigationTitle("Review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Discard", role: .destructive) { confirmDiscard = true }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { model.saveReview(watermark: watermark) }
                        .buttonStyle(.glassProminent)
                }
            }
            .confirmationDialog("Discard this photo?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard Photo", role: .destructive) { model.discardReview() }
            } message: {
                Text("It hasn't been saved. The RAW and the processed version will both be lost.")
            }
        }
        .interactiveDismissDisabled()
        .task {
            // Develop the look once at reduced size; only the watermark is redrawn on edits.
            let pending = pending
            let library = model.library
            let developed = await Task.detached(priority: .userInitiated) { () -> CIImage? in
                let cube = pending.filter.flatMap { library.cube(for: $0.id) }
                return FilteredDeveloper.previewBase(dng: pending.dng, cube: cube,
                                                     intensity: pending.filter?.intensity ?? 1,
                                                     grain: pending.grain).map { CIImage(cgImage: $0) }
            }.value
            base = developed ?? pending.result.thumbnail.flatMap(WatermarkPreview.upright)
        }
        // Re-render on every edit; a newer edit cancels the older render so it can't land last.
        .task(id: RenderKey(watermark: watermark, baseReady: base != nil)) {
            guard let base else { return }
            let image = await WatermarkPreview.render(watermark, info: info, base: base)
            if !Task.isCancelled { preview = image }
        }
    }
}
