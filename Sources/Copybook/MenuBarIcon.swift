import AppKit

/// Copybook's menu bar icon.
enum MenuBarIcon {
    enum Style {
        /// The logo's clipboard exactly (same geometry, line weight and clip gap as
        /// Support/make-icon.swift), with no background, tinted by macOS.
        case logoGlyph
        /// Kept for later: a bolder outline with shorter, thinner, centred lines.
        case boldCentered
        /// Kept for later: the full app icon, white tile included.
        case appLogo
    }

    static let style: Style = .logoGlyph

    static func image(paused: Bool) -> NSImage {
        switch style {
        case .logoGlyph: return glyph(paused: paused, outlineWeight: 42, lines: .original)
        case .boldCentered: return glyph(paused: paused, outlineWeight: 56, lines: .centered)
        case .appLogo: return appLogo(paused: paused)
        }
    }

    private enum Lines { case original, centered }

    /// Draws the clipboard in the app icon's 1024-unit design space, scaled into the menu bar slot.
    private static func glyph(paused: Bool, outlineWeight stroke: CGFloat, lines: Lines) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            // Bounds of the clipboard including half its outline, in the logo's design space.
            let board = NSRect(x: 307, y: 242, width: 410, height: 520)
            let clip = NSRect(x: 512 - 105, y: board.maxY - 52, width: 210, height: 104)
            let bounds = board.union(clip).insetBy(dx: -stroke / 2, dy: -stroke / 2)
            let scale = 17 / max(bounds.width, bounds.height)
            ctx.translateBy(x: (size.width - bounds.width * scale) / 2, y: (size.height - bounds.height * scale) / 2)
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -bounds.minX, y: -bounds.minY)

            NSColor.black.withAlphaComponent(paused ? 0.45 : 1).setStroke()

            let boardPath = NSBezierPath(roundedRect: board, xRadius: 74, yRadius: 74)
            boardPath.lineWidth = stroke
            boardPath.stroke()

            // The same gap around the clip as the logo, then the clip itself.
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(roundedRect: clip.insetBy(dx: -30, dy: -16), xRadius: 50, yRadius: 50).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            let clipPath = NSBezierPath(roundedRect: clip, xRadius: 34, yRadius: 34)
            clipPath.lineWidth = stroke
            clipPath.stroke()

            switch lines {
            case .original:
                // Same as the logo: outline weight, left-aligned, the last one shorter.
                for (y, length) in [(board.maxY - 175, CGFloat(230)), (board.maxY - 280, 230), (board.maxY - 385, 150)] {
                    let line = NSBezierPath()
                    line.move(to: NSPoint(x: 512 - 115, y: y))
                    line.line(to: NSPoint(x: 512 - 115 + length, y: y))
                    line.lineWidth = stroke
                    line.lineCapStyle = .round
                    line.stroke()
                }
            case .centered:
                for (y, length) in [(board.maxY - 175, CGFloat(180)), (board.maxY - 280, 180), (board.maxY - 385, 110)] {
                    let line = NSBezierPath()
                    line.move(to: NSPoint(x: 512 - length / 2, y: y))
                    line.line(to: NSPoint(x: 512 + length / 2, y: y))
                    line.lineWidth = 44
                    line.lineCapStyle = .round
                    line.stroke()
                }
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = paused ? "Copybook (paused)" : "Copybook"
        return image
    }

    /// The full app icon, cropped to its tile so it fills the slot; dimmed while paused.
    private static func appLogo(paused: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let icon = NSApp.applicationIconImage ?? NSImage()
        let image = NSImage(size: size, flipped: false) { rect in
            let scale: CGFloat = 1024 / 824
            let drawn = NSRect(x: rect.midX - rect.width * scale / 2, y: rect.midY - rect.height * scale / 2,
                               width: rect.width * scale, height: rect.height * scale)
            icon.draw(in: drawn, from: .zero, operation: .sourceOver, fraction: paused ? 0.45 : 1)
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = paused ? "Copybook (paused)" : "Copybook"
        return image
    }
}
