import SwiftUI

/// A segmented control drawn in SwiftUI instead of AppKit's.
///
/// `Picker` with `.segmented` hands the drawing to `NSSegmentedControl`, and
/// that looks different by the SDK the app links against and the macOS it runs
/// on: linked against the macOS 26 SDK it shrinks to its labels' width and fills
/// the chosen segment with the accent color whenever the panel is key, while
/// older linkage stretches it across the card with a neutral pill. Releases and
/// local builds link against different SDKs, so the same code shipped in one
/// look and was tested in the other. Drawing it here pins the look everywhere:
/// full width, equal segments, a neutral pill under the chosen one.
///
/// VoiceOver still gets a standard picker, via `accessibilityRepresentation`.
struct SegmentedPicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(value: Value, label: String)]
    var size: Size = .regular

    enum Size {
        /// The panel-level tab bar.
        case regular
        /// A control scoped to one card, a step below the tab bar.
        case mini

        var height: CGFloat { self == .regular ? 20 : 16 }
        var fontSize: CGFloat { self == .regular ? 11 : 10 }
        var radius: CGFloat { self == .regular ? 6 : 5 }
        /// Gap between the track's edge and the pill.
        var inset: CGFloat { self == .regular ? 2 : 1.5 }
    }

    @Environment(\.colorScheme) private var colorScheme
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                if index > 0 { divider(between: index - 1, and: index) }
                segment(option.value, label: option.label)
            }
        }
        .padding(size.inset)
        .frame(maxWidth: .infinity)
        .background(track, in: RoundedRectangle(cornerRadius: size.radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: size.radius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06))
        )
        .accessibilityRepresentation {
            Picker(title, selection: $selection) {
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                    Text(option.label).tag(option.value)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private func segment(_ value: Value, label: String) -> some View {
        let selected = value == selection
        return Button {
            selection = value
        } label: {
            Text(label)
                .font(.system(size: size.fontSize, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(height: size.height - size.inset * 2)
                .background {
                    if selected {
                        RoundedRectangle(
                            cornerRadius: size.radius - size.inset, style: .continuous
                        )
                        .fill(pillFill)
                        .shadow(color: .black.opacity(0.14), radius: 0.75, y: 0.5)
                        .matchedGeometryEffect(id: "pill", in: pill)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(SegmentButtonStyle())
        .animation(.snappy(duration: 0.22), value: selection)
    }

    /// Hairline between two unchosen neighbors; hidden beside the pill, which
    /// already separates itself.
    private func divider(between left: Int, and right: Int) -> some View {
        let hidden = [left, right].contains { options[$0].value == selection }
        return Rectangle()
            .fill(Color.primary.opacity(hidden ? 0 : 0.15))
            .frame(width: 1, height: size.height * 0.5)
    }

    private var track: Color {
        Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.06)
    }

    /// White on light, a lifted gray on dark — the neutral pill AppKit draws
    /// for an inactive window, kept whatever the window's state.
    private var pillFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.22) : .white
    }
}

/// Dims a segment while it's pressed, the only feedback a plain button would
/// otherwise lack.
private struct SegmentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.6 : 1)
    }
}
