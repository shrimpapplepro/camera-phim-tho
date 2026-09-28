import SwiftUI

/// Everything one dial needs, derived from the model for the selected parameter.
struct DialConfig: Identifiable {
    let id: String
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    var anchor: Double = 0
    let majorEvery: Double
    var detents: [Double] = []
    var pointsPerStep: CGFloat = 10
    let tickLabel: (Double) -> String
    let valueText: (Double) -> String
    let set: (Double) -> Void
}

/// The Liquid Glass panel that floats over the bottom of the viewfinder while a
/// parameter is selected: title, true value, Auto toggle, and fine dial(s) with ± steps.
struct ParameterPanel: View {
    let model: CameraModel
    let parameter: Parameter

    var body: some View {
        VStack(spacing: 10) {
            header
            if parameter == .aperture, !model.capabilities.hasVariableAperture {
                Text("This lens has a fixed \(ExposureMath.apertureText(model.capabilities.apertureStops.first ?? 0)) aperture.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 52)
            } else {
                ForEach(dials) { config in
                    dialRow(config)
                }
            }
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Label(parameter.title, systemImage: parameter.symbol)
                .font(.subheadline.weight(.semibold))
                .labelStyle(.titleAndIcon)
            Spacer()
            Text(currentText)
                .font(.title3.monospacedDigit().weight(.semibold))
                .foregroundStyle(model.isAuto(parameter) ? Color.primary : Color.yellow)
                .contentTransition(.numericText())
            if parameter != .bias, model.isAvailable(parameter) {
                autoButton
            } else if parameter == .bias, model.controls.bias != 0 {
                Button("Reset") { model.setAuto(.bias, true) }
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var autoButton: some View {
        let auto = model.isAuto(parameter)
        if auto {
            Button("Auto") { model.setAuto(parameter, false) }
                .buttonStyle(.glassProminent)
                .tint(.yellow)
                .controlSize(.small)
                .accessibilityHint("Switches \(parameter.title) to manual.")
        } else {
            Button("Auto") { model.setAuto(parameter, true) }
                .buttonStyle(.glass)
                .controlSize(.small)
                .accessibilityHint("Returns \(parameter.title) to automatic.")
        }
    }

    private func dialRow(_ config: DialConfig) -> some View {
        let grid = DialGrid(step: config.step, anchor: config.anchor, range: config.range)
        return HStack(spacing: 8) {
            Button {
                config.set(grid.nudge(config.value, by: -1))
            } label: {
                Image(systemName: "minus")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .buttonRepeatBehavior(.enabled)
            .accessibilityLabel("Decrease \(config.title)")

            FineDial(title: config.title, value: config.value, range: config.range, step: config.step,
                     anchor: config.anchor, majorEvery: config.majorEvery, detents: config.detents,
                     pointsPerStep: config.pointsPerStep / model.preferences.dialSensitivity,
                     haptics: model.preferences.haptics,
                     isDimmed: parameter == .bias && !model.biasIsEffective,
                     tickLabel: config.tickLabel, valueText: config.valueText, onChange: config.set)

            Button {
                config.set(grid.nudge(config.value, by: 1))
            } label: {
                Image(systemName: "plus")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .buttonRepeatBehavior(.enabled)
            .accessibilityLabel("Increase \(config.title)")
        }
    }

    private var note: String? {
        switch parameter {
        case .bias where !model.biasIsEffective:
            String(localized: "Everything is manual, so compensation only shifts the meter.")
        case .whiteBalance:
            String(localized: "Stored as the DNG's as-shot white point. RAW sensor data is not altered.")
        case .focus:
            String(localized: "0 is the closest focus distance; 1 is the farthest.")
        default:
            nil
        }
    }

    private var currentText: String {
        let c = model.controls, r = model.readout
        switch parameter {
        case .aperture: return ExposureMath.apertureText(c.aperture ?? r.aperture)
        case .shutter: return ExposureMath.shutterText(c.shutter ?? r.shutter)
        case .iso: return "ISO " + ExposureMath.isoText(c.iso ?? r.iso)
        case .bias: return ExposureMath.biasText(c.bias) + " EV"
        case .whiteBalance:
            let k = ExposureMath.kelvinText(c.temperature ?? r.temperature)
            let t = ExposureMath.tintText(c.temperature == nil ? r.tint : c.tint)
            return "\(k)  \(t)"
        case .focus: return ExposureMath.focusText(c.focus ?? r.lensPosition)
        }
    }

    // MARK: Dial definitions

    private var dials: [DialConfig] {
        let m = model
        let c = m.controls, r = m.readout, caps = m.capabilities
        let ev = m.preferences.stepSize.ev
        let fine = m.preferences.stepSize == .tenth

        switch parameter {
        case .aperture:
            let current = c.aperture ?? (r.aperture > 0 ? r.aperture : caps.apertureRange.lowerBound)
            return [DialConfig(
                id: "aperture", title: parameter.title,
                value: ExposureMath.apertureEV(current),
                range: ExposureMath.apertureEV(caps.apertureRange.lowerBound)...ExposureMath.apertureEV(caps.apertureRange.upperBound),
                step: ev, majorEvery: 1,
                detents: caps.apertureStops.map(ExposureMath.apertureEV),
                tickLabel: { String(format: "%.1f", ExposureMath.aperture(fromEV: $0)) },
                valueText: { ExposureMath.apertureText(ExposureMath.aperture(fromEV: $0)) },
                set: { v in m.update { $0.aperture = m.snappedAperture(ExposureMath.aperture(fromEV: v)) } })]

        case .shutter:
            let current = c.shutter ?? (r.shutter > 0 ? r.shutter : 1.0 / 125)
            return [DialConfig(
                id: "shutter", title: parameter.title,
                value: ExposureMath.shutterEV(current),
                range: ExposureMath.shutterEV(caps.shutterRange.lowerBound)...ExposureMath.shutterEV(caps.shutterRange.upperBound),
                step: ev, anchor: ExposureMath.shutterEV(1.0 / 1000), majorEvery: 1,
                tickLabel: { u in
                    let t = ExposureMath.shutter(fromEV: u)
                    let nominal = ExposureMath.standardShutters[ExposureMath.nearestIndex(of: t, in: ExposureMath.standardShutters)]
                    return ExposureMath.shutterText(nominal)
                },
                valueText: { ExposureMath.shutterText(ExposureMath.shutter(fromEV: $0)) },
                set: { v in m.update { $0.shutter = ExposureMath.shutter(fromEV: v) } })]

        case .iso:
            let current = c.iso ?? (r.iso > 0 ? r.iso : 100)
            return [DialConfig(
                id: "iso", title: parameter.title,
                value: ExposureMath.isoEV(current),
                range: ExposureMath.isoEV(caps.isoRange.lowerBound)...ExposureMath.isoEV(caps.isoRange.upperBound),
                step: ev, anchor: ExposureMath.isoEV(100), majorEvery: 1,
                tickLabel: { ExposureMath.isoText(ExposureMath.iso(fromEV: $0)) },
                valueText: { "ISO " + ExposureMath.isoText(ExposureMath.iso(fromEV: $0)) },
                set: { v in m.update { $0.iso = ExposureMath.iso(fromEV: v) } })]

        case .bias:
            return [DialConfig(
                id: "bias", title: parameter.title,
                value: Double(c.bias),
                range: Double(caps.biasRange.lowerBound)...Double(caps.biasRange.upperBound),
                step: ev, majorEvery: 1,
                tickLabel: { $0 == 0 ? "0" : String(format: "%+.0f", $0) },
                valueText: { ExposureMath.biasText(Float($0)) + " EV" },
                set: { v in m.update { $0.bias = Float(v) } })]

        case .whiteBalance:
            let kelvin = c.temperature ?? r.temperature
            let tint = c.temperature == nil ? r.tint : c.tint
            return [
                DialConfig(
                    id: "kelvin", title: String(localized: "Temperature"),
                    value: Double(kelvin.clamped(to: 2000...10000)), range: 2000...10000,
                    step: fine ? 10 : 100, majorEvery: 1000, pointsPerStep: fine ? 5 : 10,
                    tickLabel: { "\(Int($0 / 1000))K" },
                    valueText: { ExposureMath.kelvinText(Float($0)) },
                    set: { v in m.update { s in
                        s.temperature = Float(v)
                        if c.temperature == nil { s.tint = tint }
                    } }),
                DialConfig(
                    id: "tint", title: String(localized: "Tint"),
                    value: Double(tint.clamped(to: -150...150)), range: -150...150,
                    step: fine ? 1 : 5, majorEvery: 50, pointsPerStep: fine ? 6 : 10,
                    tickLabel: { String(Int($0)) },
                    valueText: { ExposureMath.tintText(Float($0)) },
                    set: { v in m.update { s in
                        s.tint = Float(v)
                        if s.temperature == nil { s.temperature = kelvin }
                    } }),
            ]

        case .focus:
            let current = c.focus ?? r.lensPosition
            return [DialConfig(
                id: "focus", title: parameter.title,
                value: Double(current), range: 0...1,
                step: fine ? 0.002 : 0.01, majorEvery: 0.1, pointsPerStep: fine ? 5 : 8,
                tickLabel: { String(format: "%.1f", $0) },
                valueText: { ExposureMath.focusText(Float($0)) },
                set: { v in m.update { $0.focus = Float(v) } })]
        }
    }
}
