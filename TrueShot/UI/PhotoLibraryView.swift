import SwiftUI

/// The photos kept in the app. Opens on a new photo the first time, the grid after that.
/// Select picks several photos to save or delete at once.
struct PhotoLibraryView: View {
    let store: PhotoStore
    @Environment(\.dismiss) private var dismiss
    @State private var path: [UUID]
    @State private var selecting = false
    @State private var selection: Set<UUID> = []
    @State private var confirmDelete = false
    @State private var saveProgress: (done: Int, total: Int)?
    @State private var alertMessage: String?

    init(store: PhotoStore) {
        self.store = store
        _path = State(initialValue: store.revealNewest().map { [$0] } ?? [])
    }

    var body: some View {
        NavigationStack(path: $path) {
            grid
                .navigationTitle(selecting ? selectionTitle : Text("Photos"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
                .navigationDestination(for: UUID.self) { id in
                    PhotoPager(store: store, id: id)
                }
                .confirmationDialog(deleteTitle, isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("Delete \(selection.count) Photos", role: .destructive) { deleteSelection() }
                } message: {
                    Text(deleteMessage)
                }
                .alert("Photos", isPresented: Binding(get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(alertMessage ?? "")
                }
        }
        .interactiveDismissDisabled(saveProgress != nil)
        .onChange(of: store.photos) { _, photos in
            selection.formIntersection(photos.map(\.id))
            if photos.isEmpty { selecting = false }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if selecting {
            ToolbarItem(placement: .topBarLeading) {
                if selection.count == store.photos.count {
                    Button("Deselect All") { selection = [] }
                } else {
                    Button("Select All") { selection = Set(store.photos.map(\.id)) }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { endSelecting() }
                    .disabled(saveProgress != nil)
            }
            ToolbarItem(placement: .bottomBar) {
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .tint(.red)
                .disabled(selection.isEmpty || saveProgress != nil)
            }
            FlexibleBottomBarSpacer()
            ToolbarItem(placement: .bottomBar) {
                if let saveProgress {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Saving \(saveProgress.done + 1) of \(saveProgress.total)…")
                            .monospacedDigit()
                    }
                } else {
                    Button {
                        saveSelection()
                    } label: {
                        Label("Save to Photos", systemImage: "square.and.arrow.down")
                            .labelStyle(.titleAndIcon)
                    }
                    .glassButtonStyle(prominent: true)
                    .disabled(unsavedSelection.isEmpty)
                }
            }
        } else {
            if !store.photos.isEmpty {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Select") { selecting = true }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
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
                        cell(photo)
                            .accessibilityLabel(Text(photo.date, format: .dateTime))
                            .accessibilityValue(photo.savedToLibrary ? String(localized: "Saved to Photos") : String(localized: "Not saved to Photos"))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func cell(_ photo: StoredPhoto) -> some View {
        let image = store.thumbnail(for: photo)
        if selecting {
            let selected = selection.contains(photo.id)
            Button {
                if selected { selection.remove(photo.id) } else { selection.insert(photo.id) }
            } label: {
                PhotoCell(image: image, saved: photo.savedToLibrary, selected: selected)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
        } else {
            NavigationLink(value: photo.id) {
                PhotoCell(image: image, saved: photo.savedToLibrary, selected: nil)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Selection

    private var selectionTitle: Text {
        selection.isEmpty ? Text("Select Photos") : Text("\(selection.count) Selected")
    }

    /// Selected photos in grid order (newest first).
    private var selectedPhotos: [StoredPhoto] { store.photos.filter { selection.contains($0.id) } }
    private var unsavedSelection: [StoredPhoto] { selectedPhotos.filter { !$0.savedToLibrary } }

    private var deleteTitle: Text {
        selection.count == 1 ? Text("Delete this photo?") : Text("Delete \(selection.count) photos?")
    }

    private var deleteMessage: String {
        let unsaved = unsavedSelection.count
        if unsaved == 0 { return String(localized: "They're removed from Phim Thô. The copies in your Photos library stay.") }
        return String(localized: "\(unsaved) of them haven't been saved to your Photos library. Their RAW and processed versions will be lost.")
    }

    private func endSelecting() {
        selecting = false
        selection = []
    }

    private func deleteSelection() {
        var failures: [String] = []
        for photo in selectedPhotos {
            do { try store.delete(photo) } catch { failures.append(error.localizedDescription) }
        }
        if let first = failures.first {
            alertMessage = String(localized: "Couldn't delete \(failures.count) photos (\(first)).")
        } else {
            endSelecting()
        }
    }

    private func saveSelection() {
        let photos = unsavedSelection
        guard !photos.isEmpty else { return }
        Task {
            var messages: [String] = []
            for (index, photo) in photos.enumerated() {
                saveProgress = (index, photos.count)
                let outcome = await store.saveToLibrary(photo)
                if let message = PhotoLibrarySaver.message(for: outcome) { messages.append(message) }
                if case .notAuthorized = outcome { break }
            }
            saveProgress = nil
            if messages.isEmpty {
                endSelecting()
            } else {
                // Keep the selection so a failed photo can be retried.
                alertMessage = Set(messages).sorted().joined(separator: "\n")
            }
        }
    }
}

private struct PhotoCell: View {
    let image: UIImage?
    let saved: Bool
    /// nil outside selection mode.
    let selected: Bool?

    var body: some View {
        Color.white.opacity(0.08)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .clipped()
            .overlay {
                if selected == true { Color.white.opacity(0.25) }
            }
            .overlay(alignment: .bottomTrailing) {
                if saved {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .green)
                        .font(.footnote)
                        .padding(4)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let selected {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .symbolRenderingMode(selected ? .palette : .monochrome)
                        .foregroundStyle(.white, .blue)
                        .font(.title3)
                        .shadow(radius: 2)
                        .padding(5)
                }
            }
            .contentShape(.rect)
    }
}

/// Swipes between photos in grid order; Delete and Save act on the one showing.
struct PhotoPager: View {
    let store: PhotoStore

    @Environment(\.dismiss) private var dismiss
    @State private var current: UUID?
    @State private var saving = false
    @State private var confirmDelete = false
    @State private var alertMessage: String?

    init(store: PhotoStore, id: UUID) {
        self.store = store
        _current = State(initialValue: id)
    }

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(store.photos) { photo in
                    PhotoPage(store: store, photo: photo)
                        .containerRelativeFrame([.horizontal, .vertical])
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $current)
        .scrollIndicators(.hidden)
        .overlay {
            if currentPhoto == nil {
                ContentUnavailableView("Photo Deleted", systemImage: "trash")
            }
        }
        .navigationTitle(currentPhoto.map { Text($0.date, format: .dateTime.day().month().hour().minute()) } ?? Text(""))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let photo = currentPhoto {
                ToolbarItem(placement: .bottomBar) {
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .tint(.red)
                }
                FlexibleBottomBarSpacer()
                ToolbarItem(placement: .bottomBar) {
                    saveButton(photo)
                }
            }
        }
        .confirmationDialog("Delete this photo?", isPresented: $confirmDelete, titleVisibility: .visible) {
            if let photo = currentPhoto {
                Button("Delete Photo", role: .destructive) { delete(photo) }
            }
        } message: {
            Text(currentPhoto?.savedToLibrary == true
                 ? "It's removed from Phim Thô. The copy in your Photos library stays."
                 : "It hasn't been saved to your Photos library. The RAW and the processed version will both be lost.")
        }
        .alert("Photos", isPresented: Binding(get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
    }

    private var currentPhoto: StoredPhoto? { current.flatMap(store.photo) }

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
            .glassButtonStyle(prominent: true)
        }
    }

    private func save(_ photo: StoredPhoto) {
        saving = true
        Task {
            let outcome = await store.saveToLibrary(photo)
            saving = false
            alertMessage = PhotoLibrarySaver.message(for: outcome)
        }
    }

    /// Deletes and moves on to the next older photo (or the newer one at the end); back to the
    /// grid when none are left.
    private func delete(_ photo: StoredPhoto) {
        let photos = store.photos
        let index = photos.firstIndex(of: photo)
        let neighbour = index.flatMap { i in
            i + 1 < photos.count ? photos[i + 1] : (i > 0 ? photos[i - 1] : nil)
        }
        do {
            try store.delete(photo)
            if let neighbour { current = neighbour.id } else { dismiss() }
        } catch {
            alertMessage = String(localized: "Couldn't delete the photo (\(error.localizedDescription)).")
        }
    }
}

/// One page of the pager: the photo, processed or RAW, and its details.
private struct PhotoPage: View {
    let store: PhotoStore
    let photo: StoredPhoto

    @State private var showRAW = false
    @State private var images: [Bool: UIImage] = [:]    // keyed by showRAW
    @State private var failedToLoad: Set<Bool> = []

    var body: some View {
        let raw = showRAW || !photo.hasProcessed
        List {
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
            metadata
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
    private var metadata: some View {
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
}
