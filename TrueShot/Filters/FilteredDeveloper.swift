import CoreImage
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

/// Develops the captured DNG and applies the selected look (LUT and/or grain), producing a HEIC companion.
/// The DNG itself is never modified.
///
/// Development uses Apple's RAW engine with noise reduction and sharpening switched off,
/// in keeping with the app's "no processing" rule; the look comes only from the LUT and grain.
enum FilteredDeveloper {
    // Metal-backed explicitly: the runtime-compiled grain kernel only runs on a Metal context.
    private static let context: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        }
        return CIContext(options: [.cacheIntermediates: false])
    }()

    static func develop(dng: Data, cube: CubeLUT?, intensity: Float, grain: GrainSettings,
                        watermark: WatermarkSettings = WatermarkSettings()) throws -> Data {
        guard let raw = CIRAWFilter(imageData: dng, identifierHint: UTType("com.adobe.raw-image")?.identifier) else {
            throw DevelopError.unreadableRAW
        }
        if raw.isLuminanceNoiseReductionSupported { raw.luminanceNoiseReductionAmount = 0 }
        if raw.isColorNoiseReductionSupported { raw.colorNoiseReductionAmount = 0 }
        if raw.isSharpnessSupported { raw.sharpnessAmount = 0 }
        if raw.isDetailSupported { raw.detailAmount = 0 }
        // Keep the sensor orientation and carry the DNG's orientation tag, like Apple's own
        // RAW+HEIC pairs: Photos pairs the two files, so their geometry should match.
        let sourceOrientation = raw.orientation
        raw.orientation = .up

        guard let developed = raw.outputImage else { throw DevelopError.unreadableRAW }
        var filtered = developed
        if let cube { filtered = LUTLibrary.apply(cube, to: filtered, intensity: intensity) }
        filtered = Grain.apply(grain, to: filtered)

        // A watermark is laid out on the upright picture, so that output is stored upright (orientation 1).
        var outputOrientation = sourceOrientation
        if watermark.isActive {
            filtered = Watermark.apply(watermark, info: PhotoInfo(dng: dng), to: filtered.oriented(sourceOrientation))
            outputOrientation = .up
        }

        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let cgImage = context.createCGImage(filtered, from: filtered.extent, format: .RGBA8, colorSpace: space) else {
            throw DevelopError.renderFailed
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.heic.identifier as CFString, 1, nil) else {
            throw DevelopError.encodeFailed
        }
        CGImageDestinationAddImage(destination, cgImage, metadata(from: dng, orientation: outputOrientation) as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw DevelopError.encodeFailed }
        return output as Data
    }

    /// A reduced, upright development of the DNG with the look and grain applied (no watermark),
    /// for the review sheet. The watermark is drawn on top of this live as the user edits it.
    static func previewBase(dng: Data, cube: CubeLUT?, intensity: Float, grain: GrainSettings,
                            maxPixel: CGFloat = 1600) -> CGImage? {
        guard let raw = CIRAWFilter(imageData: dng, identifierHint: UTType("com.adobe.raw-image")?.identifier) else { return nil }
        if raw.isLuminanceNoiseReductionSupported { raw.luminanceNoiseReductionAmount = 0 }
        if raw.isColorNoiseReductionSupported { raw.colorNoiseReductionAmount = 0 }
        if raw.isSharpnessSupported { raw.sharpnessAmount = 0 }
        if raw.isDetailSupported { raw.detailAmount = 0 }
        let native = max(raw.nativeSize.width, raw.nativeSize.height)
        if native > maxPixel { raw.scaleFactor = Float(maxPixel / native) }
        guard var image = raw.outputImage else { return nil }   // upright: orientation left at the file's value
        if let cube { image = LUTLibrary.apply(cube, to: image, intensity: intensity) }
        image = Grain.apply(grain, to: image)
        return context.createCGImage(image, from: image.extent, format: .RGBA8,
                                     colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }

    /// Carry the DNG's Exif/TIFF metadata and its orientation over (pixels are in sensor orientation).
    private static func metadata(from dng: Data, orientation: CGImagePropertyOrientation) -> [CFString: Any] {
        var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.92,
                                      kCGImagePropertyOrientation: orientation.rawValue]
        guard let source = CGImageSourceCreateWithData(dng as CFData, nil),
              let original = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return props
        }
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyExifAuxDictionary, kCGImagePropertyGPSDictionary] {
            if let value = original[key] { props[key] = value }
        }
        if var tiff = original[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = orientation.rawValue
            props[kCGImagePropertyTIFFDictionary] = tiff
        }
        return props
    }

    enum DevelopError: LocalizedError {
        case unreadableRAW, renderFailed, encodeFailed
        var errorDescription: String? {
            switch self {
            case .unreadableRAW: String(localized: "The RAW file couldn't be developed.")
            case .renderFailed: String(localized: "The filtered image couldn't be rendered.")
            case .encodeFailed: String(localized: "The filtered image couldn't be encoded.")
            }
        }
    }
}
