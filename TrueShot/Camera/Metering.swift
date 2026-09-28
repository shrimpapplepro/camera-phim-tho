import CoreGraphics
import Foundation

/// How TrueShot decides overall brightness.
///
/// Apple's auto exposure still picks shutter/ISO/aperture; TrueShot's meter measures the
/// live frames and steers AE through exposure bias toward its own target.
enum MeterMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case balanced, centerWeighted, spot, highlight, system
    var id: String { rawValue }

    var label: String {
        switch self {
        case .balanced: String(localized: "Balanced")
        case .centerWeighted: String(localized: "Center-Weighted")
        case .spot: String(localized: "Spot")
        case .highlight: String(localized: "Highlight Priority")
        case .system: String(localized: "Apple")
        }
    }

    var detail: String {
        switch self {
        case .balanced:
            String(localized: "Averages the middle 80% of the histogram to middle grey, lightly centre-weighted, and protects highlights by up to 1 stop.")
        case .centerWeighted:
            String(localized: "Like Balanced, but the centre of the frame counts much more.")
        case .spot:
            String(localized: "Meters only a small area around the point you tap (centre by default). No highlight protection.")
        case .highlight:
            String(localized: "Places the brightest 1% of the frame just below clipping: the most RAW detail without blown highlights. Pictures may look darker or brighter than middle grey.")
        case .system:
            String(localized: "Apple's own metering, unmodified.")
        }
    }
}

struct MeterStats: Sendable {
    /// Stops of change needed to put the metered mid-tones at middle grey (+ = brighten).
    var midEV: Float
    /// Stops of change that would place the brightest 1% just under clipping (+ = brighten).
    var highlightEV: Float
    /// Weighted fraction of the frame at or near clipping.
    var clipped: Float
}

enum Meter {
    /// Middle grey, as linear reflectance.
    static let middleGrey: Float = 0.18
    /// Where the 99th-percentile brightest channel should sit (sRGB code 248). The live preview is
    /// tone-mapped with a soft shoulder, so "near white" there is still below RAW clipping; on device,
    /// a 240 target held mid-tones 0.75 EV under grey with 0% of pixels clipped.
    private static let highlightTarget: Float = linear[248]
    private static let highlightPercentile: Float = 0.01
    /// Most highlight protection may pull below the mid-tone target.
    private static let maxProtection: Float = 1.0
    private static let clipCode = 250

    /// sRGB-encoded 8-bit code → linear light.
    static let linear: [Float] = (0..<256).map { i in
        let c = Float(i) / 255
        return c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4)
    }

    /// Measures a BGRA frame (sensor orientation). `spot` is in the same normalized coordinates.
    static func measure(bgra base: UnsafeRawPointer, width: Int, height: Int, bytesPerRow: Int,
                        mode: MeterMode, spot: CGPoint) -> MeterStats? {
        guard width > 8, height > 8 else { return nil }
        let step = max(1, min(width, height) / 96)       // ~96 samples on the short side
        let binsPerStop: Float = 10, minLog: Float = -14
        let binCount = Int(-minLog * binsPerStop) + 1
        var logHist = [Float](repeating: 0, count: binCount)
        var maxHist = [Float](repeating: 0, count: 256)
        var total: Float = 0
        let bytes = base.assumingMemoryBound(to: UInt8.self)

        func accumulate(useSpot: Bool) {
            var y = step / 2
            while y < height {
                let ny = (Float(y) + 0.5) / Float(height)
                let row = bytes + y * bytesPerRow
                var x = step / 2
                while x < width {
                    let nx = (Float(x) + 0.5) / Float(width)
                    let w = weight(mode: mode, useSpot: useSpot, x: nx, y: ny, spot: spot)
                    if w > 0 {
                        let p = row + x * 4
                        let b = Int(p[0]), g = Int(p[1]), r = Int(p[2])
                        let lum = 0.2126 * linear[r] + 0.7152 * linear[g] + 0.0722 * linear[b]
                        let bin = Int(((max(log2f(max(lum, 1e-6)), minLog) - minLog) * binsPerStop).rounded())
                        logHist[min(bin, binCount - 1)] += w
                        maxHist[max(r, g, b)] += w
                        total += w
                    }
                    x += step
                }
                y += step
            }
        }
        accumulate(useSpot: mode == .spot)
        if total <= 0, mode == .spot { accumulate(useSpot: false) }   // spot fell outside the frame
        guard total > 0 else { return nil }

        // Trimmed mean of log luminance between the 10th and 90th weighted percentiles.
        let lo = total * 0.10, hi = total * 0.90
        var cum: Float = 0, sum: Float = 0, count: Float = 0
        for (i, w) in logHist.enumerated() where w > 0 {
            let start = cum, end = cum + w
            cum = end
            let inside = max(0, min(end, hi) - max(start, lo))
            guard inside > 0 else { continue }
            sum += inside * (minLog + Float(i) / binsPerStop)
            count += inside
        }
        guard count > 0 else { return nil }
        let meanLog = sum / count
        let midEV = log2f(middleGrey) - meanLog

        // 99th percentile of the brightest channel (clipping happens per channel in RAW).
        var acc: Float = 0, pHigh = 255
        for code in stride(from: 255, through: 0, by: -1) {
            acc += maxHist[code]
            if acc >= total * highlightPercentile { pHigh = code; break }
        }
        var clipped: Float = 0
        for code in clipCode...255 { clipped += maxHist[code] }
        clipped /= total
        var highlightEV = log2f(highlightTarget / max(linear[pHigh], 1e-6))
        if pHigh >= clipCode { highlightEV = min(highlightEV, -0.3 - 2 * clipped) }  // how far over is unknown: step down
        return MeterStats(midEV: midEV, highlightEV: highlightEV, clipped: clipped)
    }

    private static func weight(mode: MeterMode, useSpot: Bool, x: Float, y: Float, spot: CGPoint) -> Float {
        let dx = x - 0.5, dy = y - 0.5
        let r2 = dx * dx + dy * dy
        switch mode {
        case .balanced, .system: return 1 + 1.5 * expf(-r2 / (2 * 0.35 * 0.35))
        case .centerWeighted: return 1 + 6 * expf(-r2 / (2 * 0.2 * 0.2))
        case .highlight: return 1
        case .spot:
            guard useSpot else { return 1 + 6 * expf(-r2 / (2 * 0.2 * 0.2)) }
            let sx = x - Float(spot.x), sy = y - Float(spot.y)
            return sx * sx + sy * sy <= 0.07 * 0.07 ? 1 : 0
        }
    }

    /// The exposure change TrueShot wants, in stops (+ = brighter).
    static func correction(_ s: MeterStats, mode: MeterMode) -> Float {
        switch mode {
        case .system:
            return 0
        case .spot:
            return s.midEV
        case .balanced, .centerWeighted:
            // Protect highlights, but never go more than `maxProtection` stops under the mid-tone target.
            return s.highlightEV < s.midEV ? max(s.highlightEV, s.midEV - maxProtection) : s.midEV
        case .highlight:
            return min(max(s.highlightEV, s.midEV - 3), s.midEV + 3)
        }
    }
}
