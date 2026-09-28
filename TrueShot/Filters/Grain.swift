import CoreImage
import Foundation

struct GrainSettings: Codable, Equatable, Sendable {
    /// 0 = off, 1 = heavy.
    var amount: Float = 0
    /// Grain particle size, in thousandths of the image's short side (1 ≈ ISO 400 35 mm look).
    var size: Float = 1

    var isActive: Bool { amount > 0.001 }
}

enum Grain {
    /// Strength of `amount = 1`, in gamma-encoded code values (0…1).
    private static let maxStrength: Float = 0.12

    // Film grain for gamma-encoded RGB. `noise` is uniform random RGBA; summing two channels gives
    // a triangular distribution in [-1, 1], which reads as silver grain rather than harsh digital
    // noise. Grain is monochrome and strongest in the midtones, tapering toward black and white.
    // Compiled at runtime (needs an A13 GPU or later), so no Metal toolchain is required to build.
    private static let source = """
    #include <CoreImage/CoreImage.h>
    extern "C" [[stitchable]] float4 filmGrain(coreimage::sample_t image, coreimage::sample_t noise, float amount) {
        float3 c = image.rgb;
        float luma = dot(clamp(c, 0.0, 1.0), float3(0.2126, 0.7152, 0.0722));
        float midtone = 4.0 * luma * (1.0 - luma);
        float weight = 0.2 + 0.8 * midtone;
        float g = noise.r + noise.g - 1.0;
        return float4(c + g * amount * weight, image.a);
    }
    """

    private static let kernel: CIColorKernel? = {
        (try? CIKernel.kernels(withMetalString: source))?.compactMap { $0 as? CIColorKernel }.first
    }()

    static var isAvailable: Bool { kernel != nil }

    /// Adds grain in gamma-encoded sRGB (where grain is perceived), then returns to the working space.
    /// `seed` shifts the noise field, so successive viewfinder frames get fresh grain.
    static func apply(_ settings: GrainSettings, to image: CIImage, seed: CGPoint = .zero) -> CIImage {
        guard settings.isActive, let kernel else { return image }
        let extent = image.extent
        guard extent.width.isFinite, extent.height.isFinite, extent.width > 0, extent.height > 0 else { return image }

        // Particle size scales with resolution, so the viewfinder and the full-size HEIC match.
        let shortSide = min(extent.width, extent.height)
        let particle = max(1, CGFloat(settings.size.clamped(to: 0.5...4)) * shortSide / 1000)

        let noise = CIFilter(name: "CIRandomGenerator")?.outputImage?
            .transformed(by: CGAffineTransform(translationX: seed.x, y: seed.y))
            .transformed(by: CGAffineTransform(scaleX: particle, y: particle))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent)
        guard let noise else { return image }

        let encoded = image.applyingFilter("CILinearToSRGBToneCurve")
        let amount = settings.amount.clamped(to: 0...1) * maxStrength
        guard let grained = kernel.apply(extent: extent, arguments: [encoded, noise, amount]) else { return image }
        return grained.applyingFilter("CISRGBToneCurveToLinear")
    }
}
