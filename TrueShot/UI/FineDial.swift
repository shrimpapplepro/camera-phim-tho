import SwiftUI

/// A horizontal ruler dial for fine adjustment.
///
/// Values live on a grid `anchor + k·step`. Dragging one `pointsPerStep` moves one step, and
/// every step produces a selection haptic, so 1/10-stop changes can be felt one by one.
struct FineDial: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    var anchor: Double = 0
    /// Distance between labelled major ticks, in value units.
    let majorEvery: Double
    var detents: [Double] = []
    var pointsPerStep: CGFloat = 10
    var haptics = true
    var isDimmed = false
    let tickLabel: (Double) -> String
    let valueText: (Double) -> String
    let onChange: (Double) -> Void

    @State private var dragOrigin: Double?

    var body: some View {
        Canvas { context, size in
            draw(in: &context, size: size)
        }
        .frame(height: 52)
        .overlay {
            // Fixed centre index.
            Capsule()
                .fill(.yellow)
                .frame(width: 2.5, height: 30)
                .offset(y: -6)
                .allowsHitTesting(false)
        }
        .mask {
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.18),
                                   .init(color: .black, location: 0.82), .init(color: .clear, location: 1)],
                           startPoint: .leading, endPoint: .trailing)
        }
        .opacity(isDimmed ? 0.55 : 1)
        .contentShape(.rect)
        .gesture(drag)
        .sensoryFeedback(.selection, trigger: value) { _, _ in haptics }
        .accessibilityElement()
        .accessibilityLabel(title)
        .accessibilityValue(valueText(value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: nudge(+1)
            case .decrement: nudge(-1)
            @unknown default: break
            }
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                let origin = dragOrigin ?? value
                if dragOrigin == nil { dragOrigin = origin }
                let raw = origin - Double(gesture.translation.width / pointsPerStep) * step
                let snapped = snap(raw)
                if snapped != value { onChange(snapped) }
            }
            .onEnded { _ in dragOrigin = nil }
    }

    private func nudge(_ steps: Int) {
        onChange(DialGrid(step: step, anchor: anchor, range: range).nudge(value, by: steps))
    }

    private func snap(_ raw: Double) -> Double {
        DialGrid(step: step, anchor: anchor, range: range).snap(raw)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let mid = size.width / 2
        let unitsPerPoint = step / Double(pointsPerStep)
        let halfSpan = Double(mid) * unitsPerPoint
        let first = Int(((value - halfSpan - anchor) / step).rounded(.down))
        let last = Int(((value + halfSpan - anchor) / step).rounded(.up))
        guard last >= first, last - first < 4000 else { return }

        let baseline = size.height - 18
        let tolerance = step * 0.01
        for k in first...last {
            let u = anchor + Double(k) * step
            guard u >= range.lowerBound - tolerance, u <= range.upperBound + tolerance else { continue }
            let x = mid + CGFloat((u - value) / unitsPerPoint)
            let fromMajor = (u - anchor) / majorEvery
            let isMajor = abs(fromMajor - fromMajor.rounded()) < (step / majorEvery) * 0.5
            let height: CGFloat = isMajor ? 16 : 8
            var tick = Path()
            tick.move(to: CGPoint(x: x, y: baseline - height))
            tick.addLine(to: CGPoint(x: x, y: baseline))
            context.stroke(tick, with: .color(.white.opacity(isMajor ? 0.95 : 0.45)), lineWidth: isMajor ? 1.5 : 1)
            if isMajor {
                context.draw(Text(tickLabel(u)).font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.8)),
                             at: CGPoint(x: x, y: baseline + 9))
            }
        }
        for detent in detents where abs(detent - value) <= halfSpan {
            let x = mid + CGFloat((detent - value) / unitsPerPoint)
            context.fill(Path(ellipseIn: CGRect(x: x - 2.5, y: baseline - 26, width: 5, height: 5)), with: .color(.yellow))
        }
        // Range ends.
        for end in [range.lowerBound, range.upperBound] where abs(end - value) <= halfSpan {
            let x = mid + CGFloat((end - value) / unitsPerPoint)
            var cap = Path()
            cap.move(to: CGPoint(x: x, y: baseline - 20))
            cap.addLine(to: CGPoint(x: x, y: baseline))
            context.stroke(cap, with: .color(.white), lineWidth: 2)
        }
    }
}

/// The value grid `anchor + k·step`, clamped to `range`.
struct DialGrid {
    let step: Double
    let anchor: Double
    let range: ClosedRange<Double>

    func snap(_ raw: Double) -> Double {
        let k = ((raw - anchor) / step).rounded()
        return (anchor + k * step).clamped(to: range)
    }

    /// Move by whole grid steps. From an off-grid value, the first step lands on the
    /// neighbouring grid point in that direction.
    func nudge(_ value: Double, by steps: Int) -> Double {
        let k = (value - anchor) / step
        let base = steps > 0 ? (k + 1e-6).rounded(.down) : (k - 1e-6).rounded(.up)
        return (anchor + (base + Double(steps)) * step).clamped(to: range)
    }
}
