import AppKit
import SwiftUI

/// Renders the menu-bar content (gauge icon + usage text) into a single template
/// `NSImage`. `MenuBarExtra` rasterizes a SwiftUI `Text` label at the fixed
/// system size and won't honor a custom font, so we draw it ourselves to control
/// both the point size and the vertical centering of the icon against the text.
enum MenuBarRenderer {
    /// Text point size for the menu-bar title. Smaller than the ~13pt system
    /// default that a plain SwiftUI label would be clamped to.
    static let fontSize: CGFloat = 11

    static func image(icon: String, title: String) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .medium)
        let text = NSAttributedString(
            string: title,
            attributes: [.font: font, .foregroundColor: NSColor.black]
        )
        let textSize = text.size()

        let symbolConfig = NSImage.SymbolConfiguration(pointSize: fontSize + 3, weight: .regular)
        let symbol = NSImage(systemSymbolName: icon, accessibilityDescription: title)?
            .withSymbolConfiguration(symbolConfig)
        let symbolSize = symbol?.size ?? .zero

        let spacing: CGFloat = title.isEmpty ? 0 : 3
        let width = symbolSize.width + spacing + ceil(textSize.width)
        let height = ceil(max(symbolSize.height, textSize.height))

        let image = NSImage(size: NSSize(width: max(width, 1), height: max(height, 1)))
        image.lockFocus()
        // Both icon and text are vertically centered within the shared height.
        symbol?.draw(in: NSRect(
            x: 0, y: (height - symbolSize.height) / 2,
            width: symbolSize.width, height: symbolSize.height
        ))
        text.draw(at: NSPoint(
            x: symbolSize.width + spacing,
            y: (height - textSize.height) / 2
        ))
        image.unlockFocus()

        // Template so the menu bar tints it for light/dark and the open/highlight state.
        image.isTemplate = true
        return image
    }
}
