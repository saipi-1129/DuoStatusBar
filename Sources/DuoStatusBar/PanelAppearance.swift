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
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), appearance == PanelAppearance.liquidGlass.rawValue {
            content.glassEffect(accented ? .regular.tint(color.opacity(0.22)) : .regular, in: shape)
        } else {
            content.background(color, in: shape)
        }
    }
}

extension View {
    func panelSurface<S: Shape>(_ color: Color, in shape: S, accented: Bool = false) -> some View {
        modifier(PanelSurface(color: color, shape: shape, accented: accented))
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
