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
            .foregroundStyle(Color.onInk)
            .padding(.horizontal, large ? 14 : 10).padding(.vertical, large ? 7 : 4)
            .background(Color.ink.opacity(configuration.isPressed ? 0.72 : hovering ? 0.86 : 1),
                        in: RoundedRectangle(cornerRadius: large ? 8 : 6, style: .continuous))
            .opacity(enabled ? 1 : 0.3)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == InkButtonStyle {
    static var ink: InkButtonStyle { InkButtonStyle() }
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
