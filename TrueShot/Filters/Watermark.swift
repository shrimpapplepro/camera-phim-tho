import CoreGraphics
import CoreImage
import CoreText
import Foundation
import ImageIO

// MARK: - Settings

struct WatermarkSettings: Codable, Equatable, Sendable {
    enum Style: String, Codable, CaseIterable, Identifiable, Sendable {
        case off, lightBar, darkBar, border, overlay, dateStamp
        var id: String { rawValue }
        var label: String {
            switch self {
            case .off: String(localized: "Off")
            case .lightBar: String(localized: "Light Bar")
            case .darkBar: String(localized: "Dark Bar")
            case .border: String(localized: "Border")
            case .overlay: String(localized: "Overlay")
            case .dateStamp: String(localized: "Date Stamp")
            }
        }
    }

    var style: Style = .off
    var showModel = true
    var showLens = true
    var showExposure = true
    var showDate = true
    var signature = ""

    var isActive: Bool { style != .off }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = WatermarkSettings()
        style = (try? c.decode(Style.self, forKey: .style)) ?? d.style
        showModel = (try? c.decode(Bool.self, forKey: .showModel)) ?? d.showModel
        showLens = (try? c.decode(Bool.self, forKey: .showLens)) ?? d.showLens
        showExposure = (try? c.decode(Bool.self, forKey: .showExposure)) ?? d.showExposure
        showDate = (try? c.decode(Bool.self, forKey: .showDate)) ?? d.showDate
        signature = (try? c.decode(String.self, forKey: .signature)) ?? d.signature
    }
}

// MARK: - Metadata

/// What the watermark prints, read from the photo's own Exif/TIFF metadata.
struct PhotoInfo: Equatable, Sendable {
    var make: String?
    var model: String?
    var lensModel: String?
    var focalLength: Double?        // actual, mm
    var focalLength35: Double?      // 35 mm equivalent
    var fNumber: Double?
    var exposureTime: Double?       // seconds
    var iso: Double?
    var dateOriginal: String?       // Exif "yyyy:MM:dd HH:mm:ss"

    init(make: String? = nil, model: String? = nil, lensModel: String? = nil, focalLength: Double? = nil,
         focalLength35: Double? = nil, fNumber: Double? = nil, exposureTime: Double? = nil,
         iso: Double? = nil, dateOriginal: String? = nil) {
        self.make = make; self.model = model; self.lensModel = lensModel
        self.focalLength = focalLength; self.focalLength35 = focalLength35
        self.fNumber = fNumber; self.exposureTime = exposureTime; self.iso = iso
        self.dateOriginal = dateOriginal
    }

    init(properties: [CFString: Any]) {
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        func number(_ v: Any?) -> Double? {
            if let n = v as? NSNumber { return n.doubleValue }
            if let a = v as? [NSNumber] { return a.first?.doubleValue }
            return nil
        }
        func text(_ v: Any?) -> String? {
            guard let s = (v as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
            return s
        }
        make = text(tiff[kCGImagePropertyTIFFMake])
        model = text(tiff[kCGImagePropertyTIFFModel])
        lensModel = text(exif[kCGImagePropertyExifLensModel])
        focalLength = number(exif[kCGImagePropertyExifFocalLength])
        focalLength35 = number(exif[kCGImagePropertyExifFocalLenIn35mmFilm])
        fNumber = number(exif[kCGImagePropertyExifFNumber])
        exposureTime = number(exif[kCGImagePropertyExifExposureTime])
        iso = number(exif[kCGImagePropertyExifISOSpeedRatings])
        dateOriginal = text(exif[kCGImagePropertyExifDateTimeOriginal])
    }

    init(dng: Data) {
        guard let source = CGImageSourceCreateWithData(dng as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            self.init()
            return
        }
        self.init(properties: props)
    }

    // MARK: Formatted lines

    /// "iPhone 18 Pro"; falls back to Make.
    var modelText: String? { model ?? make }

    /// "Back Triple Camera 6.86mm ƒ/1.78" — Exif LensModel with the device name removed.
    var lensText: String? {
        guard var lens = lensModel else { return nil }
        if let model, lens.hasPrefix(model) { lens = String(lens.dropFirst(model.count)) }
        lens = lens.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " f/", with: " ƒ/")
        guard let first = lens.first else { return nil }
        return first.uppercased() + lens.dropFirst()
    }

    /// "24mm  ƒ/1.8  1/120s  ISO 100" — the values actually used for this frame.
    var exposureText: String? {
        var parts: [String] = []
        if let f = focalLength35, f > 0 { parts.append("\(Int(f.rounded()))mm") }
        else if let f = focalLength, f > 0 { parts.append(String(format: "%.1fmm", f)) }
        if let n = fNumber, n > 0 { parts.append(String(format: "ƒ/%.1f", n)) }
        if let t = exposureTime, t > 0 {
            parts.append(t < 0.3 ? "1/\(Int((1 / t).rounded()))s" : String(format: "%.1fs", t))
        }
        if let iso, iso > 0 { parts.append("ISO \(Int(iso.rounded()))") }
        return parts.isEmpty ? nil : parts.joined(separator: "  ")
    }

    /// "'26 9 28" — the compact-film-camera date-back format.
    var dateStampText: String? {
        guard let raw = dateOriginal, raw.count >= 10 else { return nil }
        let chars = Array(raw)
        guard let month = Int(String(chars[5..<7])), let day = Int(String(chars[8..<10])) else { return nil }
        return "'\(String(chars[2..<4])) \(month) \(day)"
    }

    /// "2026.09.28 18:45"
    var dateText: String? {
        guard let raw = dateOriginal, raw.count >= 16 else { return nil }
        let chars = Array(raw)
        let date = String(chars[0..<10]).replacingOccurrences(of: ":", with: ".")
        let time = String(chars[11..<16])
        return "\(date) \(time)"
    }
}

// MARK: - Renderer

/// Draws the watermark with CoreGraphics/CoreText and composites it with Core Image.
/// Platform-neutral (no UIKit), so it runs the same in the app and in tests on macOS.
enum Watermark {
    private struct Palette {
        let background: CGColor, primary: CGColor, secondary: CGColor, rule: CGColor
    }

    private static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    private static func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(colorSpace: srgb, components: [r, g, b, a])!
    }
    private static let light = Palette(background: color(1, 1, 1), primary: color(0.07, 0.07, 0.08),
                                       secondary: color(0.43, 0.43, 0.45), rule: color(0.82, 0.82, 0.84))
    private static let dark = Palette(background: color(0.06, 0.06, 0.07), primary: color(0.96, 0.96, 0.97),
                                      secondary: color(0.62, 0.62, 0.65), rule: color(0.26, 0.26, 0.28))

    /// `image` must be upright (display orientation). Returns the framed image, origin at zero.
    static func apply(_ settings: WatermarkSettings, info: PhotoInfo, to image: CIImage) -> CIImage {
        guard settings.isActive else { return image }
        let photo = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let w = photo.extent.width, h = photo.extent.height
        guard w > 0, h > 0, w.isFinite, h.isFinite else { return image }
        let lines = TextLines(settings: settings, info: info)

        switch settings.style {
        case .off:
            return image
        case .lightBar, .darkBar:
            let palette = settings.style == .lightBar ? light : dark
            let barHeight = (w * 0.105).rounded()
            guard let bar = drawBar(width: w, height: barHeight, lines: lines, palette: palette) else { return photo }
            let canvas = CGRect(x: 0, y: 0, width: w, height: h + barHeight)
            return photo.transformed(by: CGAffineTransform(translationX: 0, y: barHeight))
                .composited(over: bar)
                .cropped(to: canvas)
        case .border:
            let margin = (w * 0.045).rounded()
            let bottom = (w * 0.15).rounded()
            let canvas = CGRect(x: 0, y: 0, width: w + 2 * margin, height: h + margin + bottom)
            guard let footer = drawCentered(width: canvas.width, height: bottom, lines: lines, palette: light) else { return photo }
            let paper = CIImage(color: CIColor(cgColor: light.background)).cropped(to: canvas)
            return photo.transformed(by: CGAffineTransform(translationX: margin, y: bottom))
                .composited(over: footer.composited(over: paper))
                .cropped(to: canvas)
        case .overlay:
            guard let text = drawOverlay(width: w, height: (w * 0.2).rounded(), lines: lines) else { return photo }
            return text.composited(over: photo).cropped(to: photo.extent)
        case .dateStamp:
            guard let stamp = info.dateStampText,
                  let layer = drawDateStamp(stamp, width: w, height: h) else { return photo }
            return layer.composited(over: photo).cropped(to: photo.extent)
        }
    }

    // MARK: Date stamp

    /// The orange seven-segment date of 80s/90s compact film cameras, bottom-right, drawn as
    /// geometry (no font dependency). `text` uses digits, spaces and an apostrophe.
    private static func drawDateStamp(_ text: String, width w: CGFloat, height h: CGFloat) -> CIImage? {
        let digitHeight = min(w, h) * 0.034
        let digitWidth = digitHeight * 0.55
        let stroke = digitHeight * 0.13
        let gap = digitHeight * 0.18
        let spaceWidth = digitWidth * 0.7
        let tickWidth = digitWidth * 0.35

        func advance(_ c: Character) -> CGFloat {
            switch c {
            case " ": spaceWidth
            case "'": tickWidth + gap
            default: digitWidth + gap
            }
        }
        let textWidth = text.reduce(0) { $0 + advance($1) } - gap
        let pad = digitHeight * 1.6
        let boxW = (textWidth + pad * 2).rounded(.up), boxH = (digitHeight + pad * 2).rounded(.up)
        guard let ctx = context(width: boxW, height: boxH) else { return nil }

        // Warm LED orange with a soft bloom, like light burned into film from the back.
        let orange = color(1.0, 0.55, 0.12, 0.95)
        ctx.setShadow(offset: .zero, blur: digitHeight * 0.35, color: color(1.0, 0.45, 0.05, 0.9))
        ctx.setFillColor(orange)

        // Segment rectangles in a unit cell (x 0…1, y 0…1 bottom-up), mapped to the digit box.
        let segments: [Character: String] = [
            "0": "abcdef", "1": "bc", "2": "abged", "3": "abgcd", "4": "fgbc",
            "5": "afgcd", "6": "afgedc", "7": "abc", "8": "abcdefg", "9": "abcdfg",
        ]
        func segmentRect(_ s: Character, x: CGFloat, y: CGFloat) -> CGRect {
            let t = stroke, dw = digitWidth, dh = digitHeight, half = dh / 2
            switch s {
            case "a": return CGRect(x: x + t * 0.6, y: y + dh - t, width: dw - t * 1.2, height: t)
            case "g": return CGRect(x: x + t * 0.6, y: y + half - t / 2, width: dw - t * 1.2, height: t)
            case "d": return CGRect(x: x + t * 0.6, y: y, width: dw - t * 1.2, height: t)
            case "f": return CGRect(x: x, y: y + half + t * 0.3, width: t, height: half - t * 0.9)
            case "b": return CGRect(x: x + dw - t, y: y + half + t * 0.3, width: t, height: half - t * 0.9)
            case "e": return CGRect(x: x, y: y + t * 0.6, width: t, height: half - t * 0.9)
            default:  return CGRect(x: x + dw - t, y: y + t * 0.6, width: t, height: half - t * 0.9)  // c
            }
        }

        var x = pad
        let y = pad
        for c in text {
            if let segs = segments[c] {
                for s in segs { ctx.fill(segmentRect(s, x: x, y: y)) }
            } else if c == "'" {
                ctx.fill(CGRect(x: x + tickWidth * 0.3, y: y + digitHeight * 0.68, width: stroke, height: digitHeight * 0.32))
            }
            x += advance(c)
        }
        guard let cg = ctx.makeImage() else { return nil }
        let margin = min(w, h) * 0.05
        return CIImage(cgImage: cg).transformed(by: CGAffineTransform(
            translationX: w - boxW - margin + pad, y: margin - pad))
    }

    /// The strings, chosen by the user's field toggles.
    private struct TextLines {
        var title: String?          // model (or signature when the model is hidden)
        var subtitle: String?       // lens or signature
        var exposure: String?
        var date: String?

        init(settings: WatermarkSettings, info: PhotoInfo) {
            let signature = settings.signature.trimmingCharacters(in: .whitespacesAndNewlines)
            title = settings.showModel ? info.modelText : nil
            var sub: [String] = []
            if settings.showLens, let lens = info.lensText { sub.append(lens) }
            if !signature.isEmpty { sub.append(signature) }
            if title == nil, !sub.isEmpty { title = sub.removeFirst() }
            subtitle = sub.isEmpty ? nil : sub.joined(separator: "  ·  ")
            exposure = settings.showExposure ? info.exposureText : nil
            date = settings.showDate ? info.dateText : nil
        }
    }

    // MARK: Drawing

    private static func font(_ size: CGFloat, weight: CGFloat, monospacedDigits: Bool = false) -> CTFont {
        let base = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        var attributes: [CFString: Any] = [kCTFontTraitsAttribute: [kCTFontWeightTrait: weight]]
        if monospacedDigits {
            attributes[kCTFontFeatureSettingsAttribute] = [[kCTFontFeatureTypeIdentifierKey: kNumberSpacingType,
                                                            kCTFontFeatureSelectorIdentifierKey: kMonospacedNumbersSelector]]
        }
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(CTFontCopyFontDescriptor(base), attributes as CFDictionary)
        return CTFontCreateWithFontDescriptor(descriptor, size, nil)
    }

    private static func line(_ string: String, font: CTFont, color: CGColor) -> CTLine {
        let attributed = NSAttributedString(string: string, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ])
        return CTLineCreateWithAttributedString(attributed)
    }

    private static func width(_ line: CTLine) -> CGFloat { CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) }

    /// Shrinks the font until the string fits `maxWidth`.
    private static func fitted(_ string: String, size: CGFloat, weight: CGFloat, color: CGColor,
                               maxWidth: CGFloat, mono: Bool = false) -> CTLine {
        var s = size
        var l = line(string, font: font(s, weight: weight, monospacedDigits: mono), color: color)
        while width(l) > maxWidth, s > size * 0.5 {
            s *= 0.94
            l = line(string, font: font(s, weight: weight, monospacedDigits: mono), color: color)
        }
        return l
    }

    private static func context(width: CGFloat, height: CGFloat) -> CGContext? {
        let ctx = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
                            space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.setAllowsAntialiasing(true)
        ctx?.setShouldSmoothFonts(false)
        return ctx
    }

    private static func draw(_ l: CTLine, in ctx: CGContext, x: CGFloat, baseline: CGFloat) {
        ctx.textPosition = CGPoint(x: x, y: baseline)
        CTLineDraw(l, ctx)
    }

    /// Two-column info bar: model + lens on the left, exposure + date on the right, a thin rule between.
    private static func drawBar(width w: CGFloat, height h: CGFloat, lines: TextLines, palette: Palette) -> CIImage? {
        guard let ctx = context(width: w, height: h) else { return nil }
        ctx.setFillColor(palette.background)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        let pad = h * 0.36
        let big = h * 0.25, small = h * 0.17
        let topBaseline = h * 0.53, bottomBaseline = h * 0.22
        let column = (w - 3 * pad) / 2

        var rightWidth: CGFloat = 0
        var right: [(CTLine, CGFloat)] = []
        if let e = lines.exposure {
            let l = fitted(e, size: big * 0.86, weight: 0.3, color: palette.primary, maxWidth: column, mono: true)
            right.append((l, lines.date == nil ? h * 0.40 : topBaseline)); rightWidth = max(rightWidth, width(l))
        }
        if let d = lines.date {
            let l = fitted(d, size: small, weight: 0, color: palette.secondary, maxWidth: column, mono: true)
            right.append((l, lines.exposure == nil ? h * 0.40 : bottomBaseline)); rightWidth = max(rightWidth, width(l))
        }
        for (l, y) in right { draw(l, in: ctx, x: w - pad - rightWidth, baseline: y) }

        let leftMax = right.isEmpty ? w - 2 * pad : w - 3 * pad - rightWidth - h * 0.12
        if let t = lines.title {
            draw(fitted(t, size: big, weight: 0.4, color: palette.primary, maxWidth: leftMax),
                 in: ctx, x: pad, baseline: lines.subtitle == nil ? h * 0.40 : topBaseline)
        }
        if let s = lines.subtitle {
            draw(fitted(s, size: small, weight: 0, color: palette.secondary, maxWidth: leftMax),
                 in: ctx, x: pad, baseline: lines.title == nil ? h * 0.40 : bottomBaseline)
        }
        if !right.isEmpty, lines.title != nil || lines.subtitle != nil {
            let x = w - pad - rightWidth - pad * 0.6
            ctx.setFillColor(palette.rule)
            ctx.fill(CGRect(x: x, y: h * 0.2, width: max(1, h * 0.012), height: h * 0.6))
        }
        return ctx.makeImage().map { CIImage(cgImage: $0) }
    }

    /// Centred caption under a white border: model, then exposure · date.
    private static func drawCentered(width w: CGFloat, height h: CGFloat, lines: TextLines, palette: Palette) -> CIImage? {
        guard let ctx = context(width: w, height: h) else { return nil }
        ctx.setFillColor(palette.background)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let maxWidth = w * 0.86
        var rows: [CTLine] = []
        if let t = lines.title { rows.append(fitted(t, size: h * 0.2, weight: 0.4, color: palette.primary, maxWidth: maxWidth)) }
        let detail = [lines.exposure, lines.date, lines.subtitle].compactMap { $0 }.joined(separator: "   ·   ")
        if !detail.isEmpty {
            rows.append(fitted(detail, size: h * 0.12, weight: 0, color: palette.secondary, maxWidth: maxWidth, mono: true))
        }
        let baselines: [CGFloat] = rows.count == 2 ? [h * 0.52, h * 0.26] : [h * 0.42]
        for (l, y) in zip(rows, baselines) { draw(l, in: ctx, x: (w - width(l)) / 2, baseline: y) }
        return ctx.makeImage().map { CIImage(cgImage: $0) }
    }

    /// White text with a soft shadow in the lower-left corner of the photo itself.
    private static func drawOverlay(width w: CGFloat, height h: CGFloat, lines: TextLines) -> CIImage? {
        guard let ctx = context(width: w, height: h) else { return nil }
        let pad = w * 0.04
        let white = color(1, 1, 1, 0.95), soft = color(1, 1, 1, 0.8)
        ctx.setShadow(offset: .zero, blur: w * 0.006, color: color(0, 0, 0, 0.55))
        var y = pad
        let maxWidth = w - 2 * pad
        for (text, size, weight, c, mono) in [
            (lines.date, w * 0.022, CGFloat(0), soft, true),
            ([lines.exposure, lines.subtitle].compactMap { $0 }.joined(separator: "   "), w * 0.026, CGFloat(0.2), soft, true),
            (lines.title, w * 0.038, CGFloat(0.4), white, false),
        ] {
            guard let text, !text.isEmpty else { continue }
            let l = fitted(text, size: size, weight: weight, color: c, maxWidth: maxWidth, mono: mono)
            draw(l, in: ctx, x: pad, baseline: y)
            y += size * 1.45
        }
        return ctx.makeImage().map { CIImage(cgImage: $0) }
    }
}
