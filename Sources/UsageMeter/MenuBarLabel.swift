import SwiftUI

/// Compact label shown in the menu bar itself. The gauge needle tracks the
/// pinned provider's 5hr usage; the icon is deliberately left uncolored —
/// only the in-dropdown bars change color with usage.
struct MenuBarLabel: View {
    let icon: String
    let title: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
            Text(title)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .monospacedDigit()
        }
    }
}
