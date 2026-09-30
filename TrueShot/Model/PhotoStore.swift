import Foundation
import ImageIO
import LockedCameraCapture
import Observation
import Photos
import UIKit

/// One capture kept inside the app: the untouched DNG, the developed HEIC when a look, grain
/// or watermark was on, a small thumbnail, and its details. Nothing reaches the Photos library
/// until the user saves it from the photo view.
struct StoredPhoto: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var date = Date()
    var hasProcessed = false
    /// Look, grain and watermark applied to the HEIC ("Kodak · Portra 400 + Grain 30%").
    var look: String?
    var flashFired: Bool?
    var fNumber: Double?
    var exposureTime: Double?
    var iso: Double?
    var width: Int?
    var height: Int?
    var rawBytes = 0
    var processedBytes: Int?
    var info: PhotoInfo?
    var savedToLibrary = false
}

/// The files behind `StoredPhoto`s, one folder per photo:
/// `<root>/<id>/photo.dng`, `photo.heic` (optional), `thumb.jpg`, `photo.json`.
/// `photo.json` is written last, so a folder without it is an unfinished write and is ignored.
/// Plain file operations: safe from any thread.
struct PhotoFolder: Sendable {
    let root: URL

    /// The app's own photos.
    static let app = PhotoFolder(root: URL.applicationSupportDirectory.appending(path: "Photos", directoryHint: .isDirectory))

    func directory(_ id: UUID) -> URL { root.appending(path: id.uuidString, directoryHint: .isDirectory) }
    func dngURL(_ id: UUID) -> URL { directory(id).appending(path: "photo.dng") }
    func heicURL(_ id: UUID) -> URL { directory(id).appending(path: "photo.heic") }
    func thumbnailURL(_ id: UUID) -> URL { directory(id).appending(path: "thumb.jpg") }
    private func recordURL(_ id: UUID) -> URL { directory(id).appending(path: "photo.json") }

    func add(_ record: StoredPhoto, dng: Data, heic: Data?, thumbnail: Data?) throws {
        let dir = directory(record.id)
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            try dng.write(to: dngURL(record.id), options: .atomic)
            if let heic { try heic.write(to: heicURL(record.id), options: .atomic) }
            if let thumbnail { try thumbnail.write(to: thumbnailURL(record.id), options: .atomic) }
            try write(record)
        } catch {
            try? fm.removeItem(at: dir)
            throw error
        }
    }

    func write(_ record: StoredPhoto) throws {
        try JSONEncoder().encode(record).write(to: recordURL(record.id), options: .atomic)
    }

    /// Every complete photo, newest first.
    func loadAll() -> [StoredPhoto] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        let decoder = JSONDecoder()
        return dirs.compactMap { dir -> StoredPhoto? in
            guard let id = UUID(uuidString: dir.lastPathComponent),
                  let data = try? Data(contentsOf: recordURL(id)),
                  let record = try? decoder.decode(StoredPhoto.self, from: data),
                  record.id == id,
                  fm.fileExists(atPath: dngURL(id).path) else { return nil }
            return record
        }
        .sorted { $0.date > $1.date }
    }

    func delete(_ id: UUID) throws {
        try FileManager.default.removeItem(at: directory(id))
    }

    /// Copies a photo's folder from another `PhotoFolder` (the Lock Screen camera's session content).
    func copy(_ id: UUID, from source: PhotoFolder) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let target = directory(id)
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try fm.copyItem(at: source.directory(id), to: target)
    }

    // MARK: Images

    /// An upright JPEG, at most `maxPixel` on the long side, for the grid and the shutter-row button.
    static func thumbnailJPEG(heic: Data?, rawPreview: UIImage?, maxPixel: CGFloat = 480) -> Data? {
        if let heic, let cg = downsample(CGImageSourceCreateWithData(heic as CFData, nil), maxPixel: maxPixel, always: true) {
            return UIImage(cgImage: cg).jpegData(compressionQuality: 0.85)
        }
        guard let rawPreview else { return nil }
        let size = rawPreview.size
        let scale = min(1, maxPixel / max(size.width, size.height, 1))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        // Drawing a UIImage applies its orientation, so the JPEG comes out upright.
        let upright = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            rawPreview.draw(in: CGRect(origin: .zero, size: target))
        }
        return upright.jpegData(compressionQuality: 0.85)
    }

    /// A display-sized, upright rendering of an image file. For the DNG this decodes the RAW
    /// itself (not its embedded preview).
    static func displayImage(at url: URL, maxPixel: CGFloat) -> UIImage? {
        downsample(CGImageSourceCreateWithURL(url as CFURL, nil), maxPixel: maxPixel, always: true)
            .map { UIImage(cgImage: $0) }
    }

    private static func downsample(_ source: CGImageSource?, maxPixel: CGFloat, always: Bool) -> CGImage? {
        guard let source else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: always,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary)
    }
}

/// The photos taken with Phim Thô, kept in the app until saved to Photos or deleted.
@MainActor
@Observable
final class PhotoStore {
    let folder: PhotoFolder
    /// Newest first.
    private(set) var photos: [StoredPhoto] = []
    @ObservationIgnored private var thumbnails: [UUID: UIImage] = [:]
    @ObservationIgnored private var importing = false

    init(folder: PhotoFolder) {
        self.folder = folder
        photos = folder.loadAll()
    }

    func photo(_ id: UUID) -> StoredPhoto? { photos.first { $0.id == id } }

    func insert(_ photo: StoredPhoto) {
        photos.removeAll { $0.id == photo.id }
        let index = photos.firstIndex { $0.date < photo.date } ?? photos.endIndex
        photos.insert(photo, at: index)
    }

    func thumbnail(for photo: StoredPhoto) -> UIImage? {
        if let cached = thumbnails[photo.id] { return cached }
        guard let image = UIImage(contentsOfFile: folder.thumbnailURL(photo.id).path) else { return nil }
        thumbnails[photo.id] = image
        return image
    }

    func delete(_ photo: StoredPhoto) throws {
        try folder.delete(photo.id)
        photos.removeAll { $0.id == photo.id }
        thumbnails[photo.id] = nil
    }

    /// Saves to the Photos library (HEIC with the DNG as its RAW original, or the DNG alone).
    func saveToLibrary(_ photo: StoredPhoto) async -> PhotoLibrarySaver.Outcome {
        let folder = folder
        let outcome = await PhotoLibrarySaver.save(
            dng: folder.dngURL(photo.id),
            heic: photo.hasProcessed ? folder.heicURL(photo.id) : nil,
            date: photo.date)
        switch outcome {
        case .saved, .savedSeparately:
            guard var updated = self.photo(photo.id) else { break }
            updated.savedToLibrary = true
            try? folder.write(updated)
            if let index = photos.firstIndex(where: { $0.id == photo.id }) { photos[index] = updated }
        case .notAuthorized, .failed:
            break
        }
        return outcome
    }

    // MARK: Lock Screen camera

    /// Moves photos taken on the Lock Screen (the extension's session content) into the app.
    /// Runs for the app's lifetime; a session's content is released once all of it is copied.
    func importLockedCameraContent() async {
        guard !AppRuntime.isExtension, !importing else { return }
        importing = true
        for await update in LockedCameraCaptureManager.shared.sessionContentUpdates {
            switch update {
            case .initial(let urls):
                for url in urls { await importSession(url) }
            case .added(let url):
                await importSession(url)
            case .removed:
                break
            @unknown default:
                break
            }
        }
    }

    private func importSession(_ url: URL) async {
        let source = PhotoFolder(root: url)
        let target = folder
        let found = source.loadAll()
        guard !found.isEmpty else { return }
        let copied = await Task.detached(priority: .utility) { () -> [StoredPhoto] in
            found.filter { (try? target.copy($0.id, from: source)) != nil }
        }.value
        copied.forEach(insert)
        if copied.count == found.count {
            try? await LockedCameraCaptureManager.shared.invalidateSessionContent(at: url)
        }
    }
}

/// Writes a stored photo into the Photos library.
enum PhotoLibrarySaver {
    enum Outcome: Sendable {
        case saved, savedSeparately(String), notAuthorized, failed(String)
    }

    /// With a HEIC, it is the asset's photo and the DNG its RAW alternate, so Photos shows the
    /// look and keeps the untouched RAW alongside it. If Photos rejects the pair, both files are
    /// still saved, as separate photos, and the reason is reported.
    static func save(dng dngURL: URL, heic heicURL: URL?, date: Date) async -> Outcome {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return .notAuthorized }
        let stamp = Int(date.timeIntervalSince1970)

        let dng: Data
        let heic: Data?
        do {
            dng = try Data(contentsOf: dngURL)
            heic = try heicURL.map { try Data(contentsOf: $0) }
        } catch {
            return .failed(describe(error))
        }

        guard let heic else {
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetCreationRequest.forAsset()
                        .addResource(with: .photo, data: dng, options: options("com.adobe.raw-image", "TrueShot_\(stamp).DNG"))
                }
                return .saved
            } catch {
                print("TrueShot: DNG save failed: \(describe(error)) — \(error)")
                return .failed(describe(error))
            }
        }

        // Paired the way Apple's RAW sample does it: processed photo as data with no options,
        // the DNG as a file Photos moves in. (Passing the DNG as data with a UTI and filename
        // fails with PHPhotosError 3300 "change not supported as configured" — verified on device.)
        // Photos moves the file, so it gets a temporary copy, never the app's own DNG.
        let rawURL = FileManager.default.temporaryDirectory.appending(path: "TrueShot_\(stamp)_\(UUID().uuidString.prefix(8)).dng")
        do {
            try dng.write(to: rawURL)
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: heic, options: nil)
                let rawOptions = PHAssetResourceCreationOptions()
                rawOptions.shouldMoveFile = true
                request.addResource(with: .alternatePhoto, fileURL: rawURL, options: rawOptions)
            }
            return .saved
        } catch {
            try? FileManager.default.removeItem(at: rawURL)
            let reason = describe(error)
            print("TrueShot: HEIC+DNG pair failed: \(reason) — \(error)")
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetCreationRequest.forAsset()
                        .addResource(with: .photo, data: dng, options: options("com.adobe.raw-image", "TrueShot_\(stamp).DNG"))
                    PHAssetCreationRequest.forAsset()
                        .addResource(with: .photo, data: heic, options: options("public.heic", "TrueShot_\(stamp).HEIC"))
                }
                return .savedSeparately(reason)
            } catch {
                print("TrueShot: separate save failed too: \(describe(error)) — \(error)")
                return .failed(describe(error))
            }
        }
    }

    private static func options(_ uti: String, _ filename: String) -> PHAssetResourceCreationOptions {
        let o = PHAssetResourceCreationOptions()
        o.uniformTypeIdentifier = uti
        o.originalFilename = filename
        return o
    }

    static func describe(_ error: any Error) -> String {
        let e = error as NSError
        let domain = e.domain == PHPhotosErrorDomain ? "Photos" : e.domain
        return "\(domain) \(e.code)"
    }
}
