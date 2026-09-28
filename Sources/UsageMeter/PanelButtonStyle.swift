import SwiftUI

/// The panel's small in-card buttons — "Reset now", the reset confirm, the
/// update button — drawn here rather than by AppKit, for the same reason as
/// `SegmentedPicker`: `.bordered` and `.borderedProminent` change with the SDK
/// the app links against. Against the macOS 26 SDK a `.small` button grows to
/// nearly twice the height of the 10pt label beside it, and a prominent one
/// goes gray whenever the panel isn't key. These stay compact and keep their
/// color. Callers set the font; the style only draws the chrome.
struct PanelButtonStyle: ButtonStyle {
    /// Filled with the accent: the one action a row is asking for.
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        PanelButton(configuration: configuration, prominent: prominent)
    }
}

private struct PanelButton: View {
    let configuration: ButtonStyleConfiguration
    let prominent: Bool

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        configuration.label
            .lineLimit(1)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(fill, in: shape)
            .overlay(
                shape.strokeBorder(Color.primary.opacity(prominent ? 0 : 0.12), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(prominent ? 0 : 0.08), radius: 0.5, y: 0.5)
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(shape)
    }

    private var fill: Color {
        let pressed = configuration.isPressed
        if prominent { return Color.accentColor.opacity(pressed ? 0.8 : 1) }
        if colorScheme == .dark { return Color.white.opacity(pressed ? 0.22 : 0.14) }
        return pressed ? Color(white: 0.9) : .white
    }
}
