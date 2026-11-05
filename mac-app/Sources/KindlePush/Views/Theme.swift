import SwiftUI
import AppKit

extension Color {
    /// Ink: black in light mode, white in dark mode. The app's only accent.
    static let ink = Color.primary
    /// What sits on ink: the window background.
    static let onInk = Color(nsColor: .windowBackgroundColor)
}

/// Solid ink primary button, in place of the system blue prominent style.
struct InkButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.controlSize) private var size
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        let large = size == .large
        configuration.label
            .font(large ? .body.weight(.medium) : .callout.weight(.medium))
            .foregroundStyle(enabled ? Color.onInk : Color.secondary)
            .frame(minHeight: large ? 22 : 16)
            .padding(.horizontal, large ? 14 : 10).padding(.vertical, large ? 7 : 4)
            // Disabled: a quiet grey fill with readable grey text, not a faded ink block.
            .background(enabled ? Color.ink.opacity(configuration.isPressed ? 0.72 : hovering ? 0.86 : 1)
                                : Color.primary.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: large ? 8 : 6, style: .continuous))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == InkButtonStyle {
    static var ink: InkButtonStyle { InkButtonStyle() }
}

/// Outlined companion to the ink button: same font, padding and corner, so the two sit at one height.
struct InkOutlineButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.controlSize) private var size
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        let large = size == .large
        let shape = RoundedRectangle(cornerRadius: large ? 8 : 6, style: .continuous)
        configuration.label
            .font(large ? .body.weight(.medium) : .callout.weight(.medium))
            .foregroundStyle(enabled ? Color.primary : Color.secondary)
            .frame(minHeight: large ? 22 : 16)
            .padding(.horizontal, large ? 14 : 10).padding(.vertical, large ? 7 : 4)
            .background(Color.primary.opacity(configuration.isPressed ? 0.1 : hovering && enabled ? 0.05 : 0), in: shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(enabled ? 0.22 : 0.12), lineWidth: 1))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == InkOutlineButtonStyle {
    static var inkOutline: InkOutlineButtonStyle { InkOutlineButtonStyle() }
}

/// A square icon button with a hover tint, for toolbar-like rows. Pair with `.help` and an accessibility label.
struct IconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.iconOnly)
            .font(.system(size: 14, weight: .regular))
            .foregroundStyle(enabled ? Color.primary.opacity(hovering ? 1 : 0.7) : Color.secondary.opacity(0.5))
            .frame(width: 28, height: 26)
            .background(Color.primary.opacity(configuration.isPressed ? 0.12 : hovering && enabled ? 0.07 : 0),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

extension ButtonStyle where Self == IconButtonStyle {
    static var icon: IconButtonStyle { IconButtonStyle() }
}

/// Text link in ink, underlined on hover: replaces the system blue `.link` style.
struct InkLinkStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fontWeight(.medium)
            .foregroundStyle(Color.ink.opacity(enabled ? (configuration.isPressed ? 0.6 : 1) : 0.35))
            .underline(hovering && enabled)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

extension ButtonStyle where Self == InkLinkStyle {
    static var inkLink: InkLinkStyle { InkLinkStyle() }
}

/// A web link in the ink style, opened in the default browser.
struct InkLink<Label: View>: View {
    let url: URL
    @ViewBuilder let label: Label
    var body: some View {
        Button { NSWorkspace.shared.open(url) } label: { label }.buttonStyle(.inkLink)
    }
}
