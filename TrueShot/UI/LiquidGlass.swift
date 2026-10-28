import SwiftUI

// Liquid Glass with an iOS 17 floor. On iOS 26 and later these are exactly SwiftUI's glass APIs;
// earlier systems get a frosted material and the standard bordered button styles instead.

/// Mirrors SwiftUI's `Glass` (`.regular`, `.clear`, `.tint(_:)`, `.interactive()`).
struct GlassLook {
    var clear = false
    var tint: Color?
    var isInteractive = false

    static let regular = GlassLook()
    static let clear = GlassLook(clear: true)

    func tint(_ color: Color) -> GlassLook {
        var look = self
        look.tint = color
        return look
    }

    func interactive() -> GlassLook {
        var look = self
        look.isInteractive = true
        return look
    }

    @available(iOS 26.0, *)
    var glass: Glass {
        var glass: Glass = clear ? .clear : .regular
        if let tint { glass = glass.tint(tint) }
        if isInteractive { glass = glass.interactive() }
        return glass
    }
}

extension View {
    @ViewBuilder
    func liquidGlass(_ look: GlassLook = .regular, in shape: some Shape) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(look.glass, in: shape)
        } else {
            background {
                ZStack {
                    shape.fill(look.clear ? AnyShapeStyle(.ultraThinMaterial.opacity(0.5)) : AnyShapeStyle(.ultraThinMaterial))
                    if let tint = look.tint { shape.fill(tint) }
                }
            }
        }
    }

    /// `.buttonStyle(.glass)`, or `.glassProminent` when `prominent`.
    @ViewBuilder
    func glassButtonStyle(prominent: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
        }
    }
}

/// `GlassEffectContainer`, or just the content before iOS 26.
struct LiquidGlassContainer<Content: View>: View {
    var spacing: CGFloat?
    @ViewBuilder var content: Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// `ToolbarSpacer(.flexible, placement: .bottomBar)`, or a spacer item before iOS 26.
struct FlexibleBottomBarSpacer: ToolbarContent {
    var body: some ToolbarContent {
        if #available(iOS 26.0, *) {
            ToolbarSpacer(.flexible, placement: .bottomBar)
        } else {
            ToolbarItem(placement: .bottomBar) { Spacer() }
        }
    }
}
