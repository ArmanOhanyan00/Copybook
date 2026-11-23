import AppKit
import SwiftUI

/// App names, icons and a representative colour derived from each app's icon.
@MainActor
enum AppInfo {
    private static var icons: [String: NSImage] = [:]
    private static var colors: [String: NSColor] = [:]
    private static var names: [String: String] = [:]

    static func url(for bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    static func name(for bundleID: String) -> String? {
        if let n = names[bundleID] { return n }
        guard let url = url(for: bundleID) else { return nil }
        var n = FileManager.default.displayName(atPath: url.path)
        if n.hasSuffix(".app") { n = String(n.dropLast(4)) }
        names[bundleID] = n
        return n
    }

    static func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let i = icons[bundleID] { return i }
        guard let url = url(for: bundleID) else { return nil }
        let i = NSWorkspace.shared.icon(forFile: url.path)
        icons[bundleID] = i
        return i
    }

    static func color(for bundleID: String?) -> NSColor {
        let fallback = NSColor(srgbRed: 0.56, green: 0.56, blue: 0.58, alpha: 1)
        guard let bundleID else { return fallback }
        if let c = colors[bundleID] { return c }
        let c = icon(for: bundleID).flatMap(dominantColor).map(headerTone) ?? fallback
        colors[bundleID] = c
        return c
    }

    /// Turns a raw icon colour into a clean, vivid header colour that carries white text:
    /// saturated hues are pushed to full, bright colours; greys become a neutral mid grey.
    static func headerTone(_ raw: NSColor) -> NSColor {
        guard let c = raw.usingColorSpace(.sRGB) else { return raw }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        if s < 0.2 { return NSColor(srgbRed: 0.56, green: 0.56, blue: 0.58, alpha: 1) }
        let hueDeg = h * 360
        // Yellows and greens read as muddy when darkened, so keep them bright.
        let isWarmLight = (40...75).contains(hueDeg)
        let sat = min(1, max(s, 0.72))
        let bri = isWarmLight ? max(b, 0.92) : min(0.94, max(b, 0.80))
        return NSColor(hue: h, saturation: sat, brightness: bri, alpha: 1)
    }

    /// Picks the most prominent saturated hue in the icon; falls back to its average neutral tone.
    static func dominantColor(of image: NSImage) -> NSColor? {
        let n = 40
        guard let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var rect = NSRect(x: 0, y: 0, width: n, height: n)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
        guard let raw = ctx.data else { return nil }
        let px = raw.bindMemory(to: UInt8.self, capacity: n * n * 4)

        var weight = [Double](repeating: 0, count: 12)
        var sum = [(Double, Double, Double)](repeating: (0, 0, 0), count: 12)
        var neutralCount = 0.0
        var neutral = (0.0, 0.0, 0.0)

        for i in 0..<(n * n) {
            let a = Double(px[i * 4 + 3]) / 255
            guard a > 0.85 else { continue }
            let r = Double(px[i * 4]) / 255 / a
            let g = Double(px[i * 4 + 1]) / 255 / a
            let b = Double(px[i * 4 + 2]) / 255 / a
            let mx = max(r, g, b), mn = min(r, g, b)
            let sat = mx == 0 ? 0 : (mx - mn) / mx
            if sat < 0.28 || mx < 0.18 {
                neutralCount += 1
                neutral.0 += r; neutral.1 += g; neutral.2 += b
                continue
            }
            let d = mx - mn
            var h: Double
            if mx == r { h = (g - b) / d } else if mx == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
            h *= 60
            if h < 0 { h += 360 }
            let bin = min(11, Int(h / 30))
            let w = sat * mx
            weight[bin] += w
            sum[bin].0 += r * w; sum[bin].1 += g * w; sum[bin].2 += b * w
        }

        if let best = weight.indices.max(by: { weight[$0] < weight[$1] }), weight[best] > 25 {
            let w = weight[best]
            return NSColor(srgbRed: sum[best].0 / w, green: sum[best].1 / w, blue: sum[best].2 / w, alpha: 1)
        }
        if neutralCount > 0 {
            var c = (neutral.0 / neutralCount, neutral.1 / neutralCount, neutral.2 / neutralCount)
            // Keep neutral headers readable: avoid near-white.
            let l = (c.0 + c.1 + c.2) / 3
            if l > 0.8 { c = (c.0 * 0.6, c.1 * 0.6, c.2 * 0.6) }
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        }
        return nil
    }
}

extension NSColor {
    var luminance: Double {
        guard let c = usingColorSpace(.sRGB) else { return 0.5 }
        return 0.2126 * Double(c.redComponent) + 0.7152 * Double(c.greenComponent) + 0.0722 * Double(c.blueComponent)
    }

    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "#000000" }
        return String(format: "#%02X%02X%02X", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    }
}

enum ColorParser {
    /// Accepts #RGB, #RRGGBB, #RRGGBBAA, rgb(r,g,b) and rgba(r,g,b,a).
    static func parse(_ s: String) -> NSColor? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count <= 40, !t.contains("\n") else { return nil }
        if t.hasPrefix("#") {
            let hex = String(t.dropFirst())
            guard [3, 6, 8].contains(hex.count), let v = UInt64(hex, radix: 16) else { return nil }
            switch hex.count {
            case 3:
                let r = Double((v >> 8) & 0xF) / 15, g = Double((v >> 4) & 0xF) / 15, b = Double(v & 0xF) / 15
                return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
            case 6:
                return NSColor(srgbRed: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255, alpha: 1)
            default:
                return NSColor(srgbRed: Double((v >> 24) & 0xFF) / 255, green: Double((v >> 16) & 0xFF) / 255,
                               blue: Double((v >> 8) & 0xFF) / 255, alpha: Double(v & 0xFF) / 255)
            }
        }
        let lower = t.lowercased()
        guard lower.hasPrefix("rgb(") || lower.hasPrefix("rgba("), lower.hasSuffix(")"),
              let open = lower.firstIndex(of: "(") else { return nil }
        let inner = lower[lower.index(after: open)..<lower.index(before: lower.endIndex)]
        let parts = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 3 || parts.count == 4 else { return nil }
        let nums = parts.compactMap(Double.init)
        guard nums.count == parts.count, nums[0...2].allSatisfy({ (0...255).contains($0) }) else { return nil }
        let alpha = nums.count == 4 ? nums[3] : 1
        return NSColor(srgbRed: nums[0] / 255, green: nums[1] / 255, blue: nums[2] / 255, alpha: alpha)
    }
}


enum RelativeTime {
    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    static func string(_ date: Date, now: Date = Date()) -> String {
        if now.timeIntervalSince(date) < 60 { return "Just now" }
        return formatter.localizedString(for: date, relativeTo: now).capitalizedFirst
    }
}

extension RelativeTime {
    /// Compact form for card headers: "now", "4m", "3h", "2d", then a date.
    static func short(_ date: Date, now: Date = Date()) -> String {
        let s = max(0, now.timeIntervalSince(date))
        switch s {
        case ..<60: return "now"
        case ..<3600: return "\(Int(s / 60))m"
        case ..<86_400: return "\(Int(s / 3600))h"
        case ..<(86_400 * 7): return "\(Int(s / 86_400))d"
        default: return date.formatted(.dateTime.month(.abbreviated).day())
        }
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
