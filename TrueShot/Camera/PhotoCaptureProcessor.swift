@preconcurrency import AVFoundation
import ImageIO
import UIKit

struct CapturedPhoto: Sendable {
    let dng: Data
    let result: CaptureResult
}

/// Delegate for one capture. AVFoundation calls it on a single internal queue, in order:
/// willCapture → didFinishProcessingPhoto → didFinishCapture.
final class PhotoCaptureProcessor: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let willCapture: @Sendable () -> Void
    private let completion: (Result<CapturedPhoto, CameraError>) -> Void
    private var photo: CapturedPhoto?
    private var failure: CameraError?

    init(willCapture: @escaping @Sendable () -> Void,
         completion: @escaping (Result<CapturedPhoto, CameraError>) -> Void) {
        self.willCapture = willCapture
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        willCapture()
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: (any Error)?) {
        if let error {
            failure = .captureFailed(error.localizedDescription)
            return
        }
        guard photo.isRawPhoto, let data = photo.fileDataRepresentation() else {
            failure = .noData
            return
        }

        var result = CaptureResult()
        result.byteCount = data.count
        result.pixelSize = CGSize(width: Int(photo.resolvedSettings.rawPhotoDimensions.width),
                                  height: Int(photo.resolvedSettings.rawPhotoDimensions.height))

        let metadata = photo.metadata
        if let exif = metadata[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            result.fNumber = (exif[kCGImagePropertyExifFNumber as String] as? NSNumber)?.doubleValue
            result.exposureTime = (exif[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue
            result.iso = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.doubleValue
        }

        if let preview = photo.previewCGImageRepresentation() {
            let raw = (metadata[kCGImagePropertyOrientation as String] as? NSNumber)?.uint32Value ?? 1
            let orientation = CGImagePropertyOrientation(rawValue: raw) ?? .up
            result.thumbnail = UIImage(cgImage: preview, scale: 1, orientation: UIImage.Orientation(orientation))
        }
        self.photo = CapturedPhoto(dng: data, result: result)
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: (any Error)?) {
        if let photo {
            completion(.success(photo))
        } else if let error {
            completion(.failure(.captureFailed(error.localizedDescription)))
        } else {
            completion(.failure(failure ?? .noData))
        }
    }
}

extension UIImage.Orientation {
    init(_ cg: CGImagePropertyOrientation) {
        switch cg {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        }
    }
}
