import Foundation

/// Conversions between physical values and "dial units".
///
/// Aperture, shutter and ISO dials work in EV (stops of light) so one fine step
/// is the same amount of light on every dial.
enum ExposureMath {
    // ƒ-number N: light ∝ 1/N², so EV = 2·log2(N).
    static func apertureEV(_ n: Float) -> Double { 2 * log2(Double(n)) }
    static func aperture(fromEV ev: Double) -> Float { Float(pow(2, ev / 2)) }

    static func shutterEV(_ seconds: Double) -> Double { log2(seconds) }
    static func shutter(fromEV ev: Double) -> Double { pow(2, ev) }

    static func isoEV(_ iso: Float) -> Double { log2(Double(iso)) }
    static func iso(fromEV ev: Double) -> Float { Float(pow(2, ev)) }

    // MARK: Formatting

    static func apertureText(_ n: Float) -> String {
        n <= 0 ? "ƒ/–" : String(format: "ƒ/%.1f", n)
    }

    static func shutterText(_ seconds: Double) -> String {
        guard seconds > 0, seconds.isFinite else { return "–" }
        if seconds < 0.3 {
            return "1/\(Int((1 / seconds).rounded()))"
        }
        let rounded = (seconds * 10).rounded() / 10
        return rounded == rounded.rounded() ? "\(Int(rounded))″" : String(format: "%.1f″", rounded)
    }

    static func isoText(_ iso: Float) -> String { "\(Int(iso.rounded()))" }

    static func biasText(_ ev: Float) -> String {
        let v = (ev * 10).rounded() / 10
        if v == 0 { return "±0.0" }
        return String(format: "%+.1f", v)
    }

    static func kelvinText(_ k: Float) -> String { "\(Int((k / 10).rounded() * 10))K" }

    static func tintText(_ t: Float) -> String {
        let v = Int(t.rounded())
        return v == 0 ? "0" : String(format: "%+d", v)
    }

    static func focusText(_ p: Float) -> String { String(format: "%.3f", p) }

    // MARK: Standard 1/3-stop scales, used by the Camera Control index pickers

    static let standardShutters: [Double] = [
        1.0/8000, 1.0/6400, 1.0/5000, 1.0/4000, 1.0/3200, 1.0/2500, 1.0/2000, 1.0/1600,
        1.0/1250, 1.0/1000, 1.0/800, 1.0/640, 1.0/500, 1.0/400, 1.0/320, 1.0/250, 1.0/200,
        1.0/160, 1.0/125, 1.0/100, 1.0/80, 1.0/60, 1.0/50, 1.0/40, 1.0/30, 1.0/25, 1.0/20,
        1.0/15, 1.0/13, 1.0/10, 1.0/8, 1.0/6, 1.0/5, 1.0/4, 0.3, 0.4, 0.5, 0.6, 0.8,
        1, 1.3, 1.6, 2, 2.5, 3.2, 4, 5, 6, 8, 10,
    ]

    static let standardISOs: [Float] = [
        20, 25, 32, 40, 50, 64, 80, 100, 125, 160, 200, 250, 320, 400, 500, 640, 800,
        1000, 1250, 1600, 2000, 2500, 3200, 4000, 5000, 6400, 8000, 10000, 12800,
        16000, 20000, 25600,
    ]

    static func nearestIndex<T: BinaryFloatingPoint>(of value: T, in values: [T]) -> Int {
        guard !values.isEmpty else { return 0 }
        let target = log2(Double(value))
        var best = 0
        var bestDistance = Double.infinity
        for (i, v) in values.enumerated() {
            let d = abs(log2(Double(v)) - target)
            if d < bestDistance { best = i; bestDistance = d }
        }
        return best
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
