import AppKit
import SwiftUI

enum PanelAppearance: String {
    case classic, liquidGlass
    static var supportsGlass: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }
    static var usesGlass: Bool {
        supportsGlass && UserDefaults.standard.string(forKey: "panelAppearance") == liquidGlass.rawValue
    }
}

private struct PanelSurface<S: Shape>: ViewModifier {
    @AppStorage("panelAppearance") private var appearance = PanelAppearance.classic.rawValue
    let color: Color
    let shape: S
    let accented: Bool
    let usesNativeGlass: Bool
    let interactive: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *),
           appearance == PanelAppearance.liquidGlass.rawValue {
            if usesNativeGlass {
                let regular = accented ? Glass.regular.tint(color.opacity(0.18)) : Glass.regular
                content.glassEffect(interactive ? regular.interactive() : regular, in: shape)
            } else if color == .clear {
                content
            } else {
                content.background(accented ? color : Color.primary.opacity(0.08), in: shape)
            }
        } else {
            content.background(color, in: shape)
        }
    }
}

private struct PanelGlassContainer: ViewModifier {
    let enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), enabled {
            GlassEffectContainer(spacing: 0) {
                content
            }
        } else {
            content
        }
    }
}

private struct PanelGlassButton: ViewModifier {
    let enabled: Bool
    let shape: ButtonBorderShape

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), enabled {
            content
                .buttonStyle(.glass)
                .buttonBorderShape(shape)
        } else {
            content.buttonStyle(.plain)
        }
    }
}

private struct PanelBackdrop: ViewModifier {
    let enabled: Bool
    let reduceTransparency: Bool
    let fallback: Color
    let tint: Color
    let cornerRadius: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), enabled, !reduceTransparency {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            content.background {
                shape.fill(.clear)
                    .glassEffect(.regular.tint(tint.opacity(0.10)), in: shape)
            }
        } else {
            content.background(fallback)
        }
    }
}

extension View {
    func panelSurface<S: Shape>(
        _ color: Color,
        in shape: S,
        accented: Bool = false,
        usesNativeGlass: Bool = false,
        interactiveGlass: Bool = false
    ) -> some View {
        modifier(PanelSurface(
            color: color,
            shape: shape,
            accented: accented,
            usesNativeGlass: usesNativeGlass,
            interactive: interactiveGlass
        ))
    }

    func panelGlassContainer(enabled: Bool) -> some View {
        modifier(PanelGlassContainer(enabled: enabled))
    }

    func panelGlassButton(enabled: Bool, shape: ButtonBorderShape = .automatic) -> some View {
        modifier(PanelGlassButton(enabled: enabled, shape: shape))
    }

    func panelBackdrop(
        enabled: Bool,
        reduceTransparency: Bool,
        fallback: Color,
        tint: Color,
        cornerRadius: CGFloat
    ) -> some View {
        modifier(PanelBackdrop(
            enabled: enabled,
            reduceTransparency: reduceTransparency,
            fallback: fallback,
            tint: tint,
            cornerRadius: cornerRadius
        ))
    }
}

final class GlassDashboardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 380, height: 492),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        isReleasedWhenClosed = false
        isMovableByWindowBackground = false
        collectionBehavior = [.transient, .fullScreenAuxiliary]
    }
}
