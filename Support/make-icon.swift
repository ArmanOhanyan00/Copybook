// Renders Copybook's app icon into an .iconset folder: a clipboard glyph (drawn here from
// scratch, so no SF Symbol artwork is used) on a white rounded square.
// Usage: swift make-icon.swift <output.iconset> [original|centered]
//   original (default): lines the same weight as the outline, left-aligned.
//   centered: shorter, thinner, centred lines (an alternative kept for later).
import AppKit

let lineStyle = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "original"

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    // Work in a 1024 × 1024 design space (macOS icon grid: 824 pt body, 100 pt margins).
    let k = CGFloat(px) / 1024
    ctx.scaleBy(x: k, y: k)

    // White tile with a gentle top-to-bottom tone and a soft drop shadow.
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    NSColor.white.setFill()
    tilePath.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [NSColor(white: 1, alpha: 1), NSColor(srgbRed: 0.94, green: 0.945, blue: 0.955, alpha: 1)])!
        .draw(in: tilePath, angle: -90)
    NSColor.black.withAlphaComponent(0.06).setStroke()
    tilePath.lineWidth = 2
    tilePath.stroke()

    let ink = NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1)
    let stroke: CGFloat = 42

    // Board: an outlined rounded rectangle.
    let board = NSRect(x: 512 - 205, y: 512 - 270, width: 410, height: 520)
    let boardPath = NSBezierPath(roundedRect: board, xRadius: 74, yRadius: 74)
    boardPath.lineWidth = stroke
    ink.setStroke()
    boardPath.stroke()

    // Clip: punch a gap in the board's top edge, then draw the outlined clip over it.
    let clip = NSRect(x: 512 - 105, y: board.maxY - 52, width: 210, height: 104)
    let clipPath = NSBezierPath(roundedRect: clip, xRadius: 34, yRadius: 34)
    NSGraphicsContext.saveGraphicsState()
    NSGradient(colors: [NSColor(white: 1, alpha: 1), NSColor(srgbRed: 0.94, green: 0.945, blue: 0.955, alpha: 1)])!
        .draw(in: NSBezierPath(roundedRect: clip.insetBy(dx: -30, dy: -16), xRadius: 50, yRadius: 50), relativeCenterPosition: .zero)
    NSGraphicsContext.restoreGraphicsState()
    clipPath.lineWidth = stroke
    clipPath.stroke()

    // List lines.
    if lineStyle == "centered" {
        // Kept for reference: thinner than the outline, inset from the sides, all centred.
        let lines: [(CGFloat, CGFloat)] = [(board.maxY - 175, 180), (board.maxY - 280, 180), (board.maxY - 385, 110)]
        for (y, length) in lines {
            let p = NSBezierPath()
            p.move(to: NSPoint(x: 512 - length / 2, y: y))
            p.line(to: NSPoint(x: 512 + length / 2, y: y))
            p.lineWidth = 32
            p.lineCapStyle = .round
            p.stroke()
        }
    } else {
        // Original: same weight as the outline, left-aligned, the last one shorter.
        let lines: [(CGFloat, CGFloat)] = [(board.maxY - 175, 230), (board.maxY - 280, 230), (board.maxY - 385, 150)]
        for (y, length) in lines {
            let p = NSBezierPath()
            p.move(to: NSPoint(x: 512 - 115, y: y))
            p.line(to: NSPoint(x: 512 - 115 + length, y: y))
            p.lineWidth = stroke
            p.lineCapStyle = .round
            p.stroke()
        }
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).write(to: out.appendingPathComponent("icon_\(name).png"))
}
