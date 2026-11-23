import CoreGraphics
import Foundation

/// How clips are laid out: as cards, or as a compact list of rows.
enum CardFormat: String, CaseIterable, Identifiable {
    case cards, list
    var id: String { rawValue }
    var title: String { self == .cards ? "Cards" : "List" }
}

/// The shape of a card. Fixed shapes keep their proportions however the panel is resized;
/// Automatic is the original look (nearly square along the bottom, wide rows down the side).
enum CardShape: String, CaseIterable, Identifiable {
    case automatic, square, landscape, wide, portrait, tall
    var id: String { rawValue }

    /// Width divided by height; nil for Automatic.
    var ratio: CGFloat? {
        switch self {
        case .automatic: return nil
        case .square: return 1
        case .landscape: return 4.0 / 3
        case .wide: return 16.0 / 9
        case .portrait: return 3.0 / 4
        case .tall: return 9.0 / 16
        }
    }

    var title: String {
        switch self {
        case .automatic: return "Auto"
        case .square: return "Square"
        case .landscape: return "Landscape"
        case .wide: return "Wide"
        case .portrait: return "Portrait"
        case .tall: return "Tall"
        }
    }

    /// The SF Symbol that stands for this shape.
    var symbol: String {
        switch self {
        case .automatic: return "aspectratio"
        case .square: return "square"
        case .landscape: return "rectangle.ratio.4.to.3"
        case .wide: return "rectangle.ratio.16.to.9"
        case .portrait: return "rectangle.ratio.3.to.4"
        case .tall: return "rectangle.ratio.9.to.16"
        }
    }

    /// For VoiceOver and tooltips.
    var detail: String {
        switch self {
        case .automatic: return "Sized to fit the layout"
        case .square: return "Square, 1 : 1"
        case .landscape: return "Landscape, 4 : 3"
        case .wide: return "Wide, 16 : 9"
        case .portrait: return "Portrait, 3 : 4"
        case .tall: return "Tall, 9 : 16"
        }
    }
}

/// Sizing rules for cards. Pure functions, so every shape in both layouts can be checked without a window.
enum CardStyle {
    /// The horizontal strip: smallest and largest a card may be. Upright cards may grow taller, so they
    /// are not dwarfed by the wide ones.
    static let minHeight: CGFloat = 170
    static let maxHeight: CGFloat = 300
    static let maxUprightHeight: CGFloat = 400
    static let minWidth: CGFloat = 150
    static let maxWidth: CGFloat = 480
    /// Space the horizontal strip keeps on each side of the cards.
    static let stripSide: CGFloat = 20
    /// How much room a card is meant to take up when the panel opens: about this many square points,
    /// whatever its shape, so a tall card is not smaller than a wide one.
    static let preferredArea: CGFloat = 66_000

    /// The vertical panel: cards sit in as many columns as fit, never narrower or taller than this.
    static let columnGap: CGFloat = 14
    static let minColumnWidth: CGFloat = 170
    static let maxColumnHeight: CGFloat = 420
    static let maxColumns = 3

    /// Cards this wide and short put their picture beside the text instead of above it.
    static let sideMediaRatio: CGFloat = 2

    static func sideMedia(shape: CardShape, vertical: Bool) -> Bool {
        guard let r = shape.ratio else { return vertical }
        return r >= sideMediaRatio
    }

    /// The card heights the horizontal strip allows for a fixed shape: tall enough that a narrow card
    /// is still readable, short enough that a wide one doesn't grow beyond a sensible width.
    static func heightRange(for shape: CardShape) -> ClosedRange<CGFloat>? {
        guard let r = shape.ratio else { return nil }
        let lo = max(minHeight, (minWidth / r).rounded(.up))
        let cap = r < 1 ? maxUprightHeight : maxHeight
        let hi = max(lo, min(cap, (maxWidth / r).rounded(.down)))
        return lo...hi
    }

    /// The card height the horizontal strip starts at for a shape: the same amount of card whatever its shape.
    static func preferredHeight(for shape: CardShape) -> CGFloat? {
        guard let r = shape.ratio, let range = heightRange(for: shape) else { return nil }
        return min(max((preferredArea / r).squareRoot().rounded(), range.lowerBound), range.upperBound)
    }

    struct Layout: Equatable {
        var size: CGSize
        var columns: Int
    }

    /// The card size (and, in the vertical panel, how many columns fit) for a visible panel size.
    /// Horizontal: cards grow with the panel's height, never wider than the panel. Vertical: cards share
    /// the panel's width, as many side by side as fit while staying a sensible size.
    static func layout(shape: CardShape, vertical: Bool, panel: CGSize, chrome: CGFloat, inset: CGFloat, verticalHeight: CGFloat) -> Layout {
        if vertical {
            let inner = max(200, panel.width - inset * 2)
            guard let r = shape.ratio else { return Layout(size: CGSize(width: inner.rounded(), height: verticalHeight), columns: 1) }
            func column(_ n: Int) -> CGSize {
                let w = (inner - columnGap * CGFloat(n - 1)) / CGFloat(n)
                return CGSize(width: w, height: w / r)
            }
            var n = 1
            while n < maxColumns, column(n).height > maxColumnHeight, column(n + 1).width >= minColumnWidth { n += 1 }
            var c = column(n)
            if c.height > maxColumnHeight { c = CGSize(width: maxColumnHeight * r, height: maxColumnHeight) }
            return Layout(size: CGSize(width: c.width.rounded(.down), height: c.height.rounded(.down)), columns: n)
        }
        let avail = panel.height - chrome
        let room = max(200, panel.width - stripSide * 2 - 6)
        guard let r = shape.ratio, let range = heightRange(for: shape) else {
            let h = min(max(minHeight, avail), maxHeight)
            return Layout(size: CGSize(width: min(h * 0.983, room).rounded(), height: h.rounded()), columns: 1)
        }
        // A panel that has been pinned too small for the shape still gets cards that fit inside it.
        let floor = min(range.lowerBound, max(120, avail))
        var h = min(max(floor, avail), range.upperBound)
        var w = h * r
        if w > room { w = room; h = w / r }
        return Layout(size: CGSize(width: w.rounded(), height: h.rounded()), columns: 1)
    }

    /// List format: rows in as many columns as fit. A wide bar fits several; a tall panel has one.
    static let minRowWidth: CGFloat = 380
    static let maxRowWidth: CGFloat = 720
    static let maxListColumns = 4

    static func listLayout(vertical: Bool, panel: CGSize, rowHeight: CGFloat, inset: CGFloat) -> Layout {
        let inner = max(200, panel.width - inset * 2)
        let n = vertical ? 1 : min(maxListColumns, max(1, Int(((inner + columnGap) / (minRowWidth + columnGap)).rounded(.down))))
        let w = min(maxRowWidth, (inner - columnGap * CGFloat(n - 1)) / CGFloat(n))
        return Layout(size: CGSize(width: w.rounded(.down), height: rowHeight), columns: n)
    }

    static func size(shape: CardShape, vertical: Bool, panel: CGSize, chrome: CGFloat, inset: CGFloat, verticalHeight: CGFloat) -> CGSize {
        layout(shape: shape, vertical: vertical, panel: panel, chrome: chrome, inset: inset, verticalHeight: verticalHeight).size
    }
}
