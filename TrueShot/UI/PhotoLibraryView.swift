import SwiftUI

/// The photos kept in the app. Opens on the newest photo; Back shows all of them.
struct PhotoLibraryView: View {
    let store: PhotoStore
    @Environment(\.dismiss) private var dismiss
    @State private var path: [UUID]

    init(store: PhotoStore) {
        self.store = store
        _path = State(initialValue: store.photos.first.map { [$0.id] } ?? [])
    }

    var body: some View {
        NavigationStack(path: $path) {
            grid
                .navigationTitle("Photos")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
                .navigationDestination(for: UUID.self) { id in
                    PhotoDetailView(store: store, id: id)
                }
        }
    }

    @ViewBuilder
    private var grid: some View {
        if store.photos.isEmpty {
            ContentUnavailableView("No Photos", systemImage: "photo.on.rectangle",
                                   description: Text("Photos you take stay here until you save them to your library or delete them."))
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 2)], spacing: 2) {
                    ForEach(store.photos) { photo in
                        NavigationLink(value: photo.id) {
                            PhotoCell(image: store.thumbnail(for: photo), saved: photo.savedToLibrary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(photo.date, format: .dateTime))
                        .accessibilityValue(photo.savedToLibrary ? String(localized: "Saved to Photos") : String(localized: "Not saved to Photos"))
                    }
                }
            }
        }
    }
}

private struct PhotoCell: View {
    let image: UIImage?
    let saved: Bool

    var body: some View {
        Color.white.opacity(0.08)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .clipped()
            .overlay(alignment: .bottomTrailing) {
                if saved {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .green)
                        .font(.footnote)
                        .padding(4)
                }
            }
            .contentShape(.rect)
    }
}

/// One photo: processed or RAW, its details, and the only way to Photos (Save) or out (Delete).
struct PhotoDetailView: View {
    let store: PhotoStore
    let id: UUID

    @Environment(\.dismiss) private var dismiss
    @State private var showRAW = false
    @State private var images: [Bool: UIImage] = [:]    // keyed by showRAW
    @State private var failedToLoad: Set<Bool> = []
    @State private var saving = false
    @State private var confirmDelete = false
    @State private var alertMessage: String?

    var body: some View {
        if let photo = store.photo(id) {
            content(photo)
        } else {
            ContentUnavailableView("Photo Deleted", systemImage: "trash")
        }
    }

    private func content(_ photo: StoredPhoto) -> some View {
        let raw = showRAW || !photo.hasProcessed
        return List {
            Section {
                viewer(raw: raw)
                if photo.hasProcessed {
                    Picker("Version", selection: $showRAW) {
                        Text("Processed").tag(false)
                        Text("RAW").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 4, trailing: 0))
                    .listRowBackground(Color.clear)
                }
            } footer: {
                Text(raw
                     ? "The DNG as captured: sensor data without fusion, HDR or noise reduction, shown with a neutral development."
                     : "The HEIC with the look, grain and watermark it was taken with.")
            }
            metadata(photo)
        }
        .navigationTitle(Text(photo.date, format: .dateTime.day().month().hour().minute()))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .bottomBar) {
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .tint(.red)
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                saveButton(photo)
            }
        }
        .confirmationDialog("Delete this photo?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Photo", role: .destructive) { delete(photo) }
        } message: {
            Text(photo.savedToLibrary
                 ? "It's removed from Phim Thô. The copy in your Photos library stays."
                 : "It hasn't been saved to your Photos library. The RAW and the processed version will both be lost.")
        }
        .alert("Photos", isPresented: Binding(get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
        .task(id: raw) {
            guard images[raw] == nil, !failedToLoad.contains(raw) else { return }
            let url = raw ? store.folder.dngURL(photo.id) : store.folder.heicURL(photo.id)
            let image = await Task.detached(priority: .userInitiated) {
                PhotoFolder.displayImage(at: url, maxPixel: 2400)
            }.value
            if let image { images[raw] = image } else { failedToLoad.insert(raw) }
        }
    }

    private func viewer(raw: Bool) -> some View {
        ZStack {
            Color.black
            if let image = images[raw] {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .accessibilityLabel(raw ? "RAW photo" : "Processed photo")
            } else if failedToLoad.contains(raw) {
                ContentUnavailableView("Can't Show Photo", systemImage: "exclamationmark.triangle")
            } else {
                ProgressView()
            }
        }
        .frame(height: 460)
        .clipShape(.rect(cornerRadius: 12))
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
    }

    @ViewBuilder
    private func metadata(_ photo: StoredPhoto) -> some View {
        let info = photo.info
        Section("Details") {
            LabeledContent("Taken", value: photo.date.formatted(date: .abbreviated, time: .standard))
            if let camera = info?.modelText { LabeledContent("Camera", value: camera) }
            if let lens = info?.lensText { LabeledContent("Lens", value: lens) }
            if let focal = focalText(info) { LabeledContent("Focal Length", value: focal) }
            if let f = photo.fNumber { LabeledContent("Aperture", value: ExposureMath.apertureText(Float(f))) }
            if let t = photo.exposureTime { LabeledContent("Shutter", value: ExposureMath.shutterText(t)) }
            if let iso = photo.iso { LabeledContent("ISO", value: ExposureMath.isoText(Float(iso))) }
            if let fired = photo.flashFired {
                LabeledContent("Flash", value: fired ? String(localized: "Fired") : String(localized: "Didn't fire"))
            }
            if let look = photo.look { LabeledContent("Look", value: look) }
        }
        Section("File") {
            LabeledContent("Format", value: photo.hasProcessed ? String(localized: "HEIC + RAW DNG") : String(localized: "RAW DNG"))
            if let w = photo.width, let h = photo.height, w > 0, h > 0 {
                LabeledContent("Dimensions", value: "\(w) × \(h)")
            }
            LabeledContent("RAW Size", value: photo.rawBytes.formatted(.byteCount(style: .file)))
            if let bytes = photo.processedBytes {
                LabeledContent("HEIC Size", value: bytes.formatted(.byteCount(style: .file)))
            }
            LabeledContent("Photos Library", value: photo.savedToLibrary ? String(localized: "Saved") : String(localized: "Not Saved"))
        }
    }

    private func focalText(_ info: PhotoInfo?) -> String? {
        guard let info else { return nil }
        let actual = info.focalLength.flatMap { $0 > 0 ? String(format: "%.2f mm", $0) : nil }
        let equivalent = info.focalLength35.flatMap { $0 > 0 ? String(localized: "\(Int($0.rounded())) mm equiv.") : nil }
        switch (actual, equivalent) {
        case let (a?, e?): return "\(a) (\(e))"
        case let (a?, nil): return a
        case let (nil, e?): return e
        case (nil, nil): return nil
        }
    }

    @ViewBuilder
    private func saveButton(_ photo: StoredPhoto) -> some View {
        if saving {
            ProgressView()
        } else if photo.savedToLibrary {
            Label("Saved to Photos", systemImage: "checkmark.circle.fill")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.secondary)
        } else {
            Button {
                save(photo)
            } label: {
                Label("Save to Photos", systemImage: "square.and.arrow.down")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.glassProminent)
        }
    }

    private func save(_ photo: StoredPhoto) {
        saving = true
        Task {
            let outcome = await store.saveToLibrary(photo)
            saving = false
            switch outcome {
            case .saved:
                break
            case .savedSeparately(let reason):
                alertMessage = String(localized: "Saved the RAW and the HEIC as separate photos (pairing failed: \(reason)).")
            case .notAuthorized:
                alertMessage = String(localized: "Couldn't save: allow Phim Thô to add photos in Settings › Privacy › Photos.")
            case .failed(let reason):
                alertMessage = String(localized: "Couldn't save to Photos (\(reason)).")
            }
        }
    }

    private func delete(_ photo: StoredPhoto) {
        do {
            try store.delete(photo)
            dismiss()
        } catch {
            alertMessage = String(localized: "Couldn't delete the photo (\(error.localizedDescription)).")
        }
    }
}
