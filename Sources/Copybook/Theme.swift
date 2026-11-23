import AppKit
import SwiftUI

/// Shared motion constants. (Colours and layout live next to the views in `PanelStyle`.)
enum Theme {
    static let snappy = Animation.interpolatingSpring(stiffness: 420, damping: 32)
    static let gentle = Animation.interpolatingSpring(stiffness: 260, damping: 26)
}

extension Color {
    /// A colour from a 0xRRGGBB value.
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }

    /// A colour that switches with the light or dark appearance.
    static func dynamic(light: UInt32, dark: UInt32, lightAlpha: Double = 1, darkAlpha: Double = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255,
                           alpha: isDark ? darkAlpha : lightAlpha)
        })
    }
}
