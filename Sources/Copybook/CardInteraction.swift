import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Native mouse handling for a card: click to copy, double-click to paste, and a real
/// macOS drag that carries the clip's actual data (text, rich text, links, images or files),
/// so other apps accept the drop, with a rounded preview instead of a square snapshot.
final class CardInteractionView: NSView, NSDraggingSource {
    var item: ClipItem?
    weak var core: AppCore?
    var onHover: (Bool) -> Void = { _ in }

    private var downEvent: NSEvent?
    private var tracking: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }

    override func mouseDown(with event: NSEvent) { downEvent = event }

    override func mouseDragged(with event: NSEvent) {
        guard let down = downEvent else { return }
        let a = down.locationInWindow, b = event.locationInWindow
        guard hypot(b.x - a.x, b.y - a.y) > 4 else { return }
        downEvent = nil
        beginDrag(with: down)
    }

    override func mouseUp(with event: NSEvent) {
        guard let down = downEvent, let item, let core else { return }
        downEvent = nil
        MainActor.assumeIsolated {
            core.click(item, clickCount: event.clickCount, flags: down.modifierFlags)
        }
    }

    // Right-click falls through to SwiftUI, which shows the card's context menu.
    override func rightMouseDown(with event: NSEvent) { nextResponder?.rightMouseDown(with: event) }

    // MARK: Dragging

    private func beginDrag(with event: NSEvent) {
        guard let item, let core else { return }
        MainActor.assumeIsolated {
            let targets = core.targets(for: item)
            var draggingItems: [NSDraggingItem] = []
            for clip in targets {
                for writer in Paster.dragWriters(for: clip, store: core.store) {
                    draggingItems.append(NSDraggingItem(pasteboardWriter: writer))
                }
            }
            let image = DragImage.render(for: item, count: targets.count, store: core.store, appearance: effectiveAppearance)
            let point = convert(event.locationInWindow, from: nil)
            let frame = NSRect(x: point.x - image.size.width / 2, y: point.y - image.size.height / 2,
                               width: image.size.width, height: image.size.height)
            for (i, d) in draggingItems.enumerated() {
                // Only the first item shows the preview; the rest travel invisibly underneath it.
                d.setDraggingFrame(frame, contents: i == 0 ? image : nil)
            }
            // Keep this view alive and the panel open until the drop finishes, even if the
            // card list re-renders or another app takes focus mid-drag.
            Self.activeDrag = self
            let session = beginDraggingSession(with: draggingItems, event: event, source: self)
            session.animatesToStartingPositionsOnCancelOrFail = true
            session.draggingFormation = .none
        }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Dropped anywhere, a clip is copied.
        .copy
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    /// Debug hook for the drag test: reports how each drag ended.
    static var onDragEnded: ((NSDragOperation, NSPoint) -> Void)?

    /// The card being dragged right now, if any.
    static var activeDrag: CardInteractionView?
    static var isDragging: Bool { activeDrag != nil }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        Self.activeDrag = nil
        Self.onDragEnded?(operation, screenPoint)
        // Focus may have moved to the app the clip was dropped on; take it back so the
        // panel keeps working for the next drag instead of closing on the next event.
        if let panel = window, panel.isVisible, !panel.isKeyWindow { panel.makeKey() }
    }
}

struct CardInteraction: NSViewRepresentable {
    let item: ClipItem
    let core: AppCore
    let onHover: (Bool) -> Void

    func makeNSView(context: Context) -> CardInteractionView {
        let v = CardInteractionView()
        v.item = item
        v.core = core
        v.onHover = onHover
        return v
    }

    func updateNSView(_ v: CardInteractionView, context: Context) {
        v.item = item
        v.core = core
        v.onHover = onHover
    }
}

/// The picture that follows the pointer while dragging: a compact rounded card.
@MainActor
enum DragImage {
    static func render(for item: ClipItem, count: Int, store: Store, appearance: NSAppearance) -> NSImage {
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let renderer = ImageRenderer(content:
            DragPreview(item: item, count: count, store: store, dark: dark)
                .environment(\.colorScheme, dark ? .dark : .light)
                .padding(10)   // room for the shadow
        )
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        renderer.scale = scale
        renderer.isOpaque = false
        renderer.colorMode = .nonLinear   // plain sRGB, not an extended-range bitmap
        guard let cg = renderer.cgImage else { return NSImage(size: NSSize(width: 1, height: 1)) }
        return NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / scale, height: CGFloat(cg.height) / scale))
    }
}

private struct DragPreview: View {
    let item: ClipItem
    let count: Int
    @ObservedObject var store: Store
    let dark: Bool

    // Explicit colours: offscreen rendering doesn't resolve system/dynamic colours reliably.
    private var surface: Color { dark ? Color(white: 0.13) : .white }
    private var primary: Color { dark ? .white : Color(white: 0.1) }
    private var secondary: Color { dark ? Color(white: 0.68) : Color(white: 0.42) }
    private var edge: Color { dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if let icon = AppInfo.icon(for: item.sourceBundleID).map(flattened) {
                    Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                }
                Text(item.title ?? item.sourceAppName ?? item.kind.label)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            content
        }
        .padding(12)
        .frame(width: 210, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(surface))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(edge, lineWidth: 0.5))
        .overlay(alignment: .topTrailing) {
            if count > 1 {
                Text("\(count)")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(minWidth: 22, minHeight: 22)
                    .background(Circle().fill(Color.accentColor))
                    .offset(x: 8, y: -8)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(0.001))
                .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
        )
    }

    /// App icons can carry extended-range colour, which turns the whole offscreen render into a
    /// 64-bit image that comes out greyed. Redraw the icon into a plain 8-bit sRGB bitmap first.
    private func flattened(_ icon: NSImage) -> NSImage {
        let px = 64
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)?
            .retagging(with: .sRGB) else { return icon }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        icon.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let out = NSImage(size: NSSize(width: 32, height: 32))
        out.addRepresentation(rep)
        return out
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .image:
            if let img = store.displayImage(item, maxPixel: 600) {
                Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                    .frame(height: 96).frame(maxWidth: .infinity).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
        case .link:
            Text(item.linkTitle ?? item.text ?? "")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(primary)
                .lineLimit(2)
            Text(item.linkURL?.host ?? "")
                .font(.system(size: 11.5))
                .foregroundStyle(secondary)
        case .color:
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: ColorParser.parse(item.text ?? "") ?? .gray))
                .frame(height: 44)
        case .file:
            Text((item.filePaths ?? []).map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(primary)
                .lineLimit(2)
        case .text:
            Text(String((item.text ?? "").prefix(160)))
                .font(.system(size: 13))
                .foregroundStyle(primary)
                .lineLimit(3)
        }
    }
}
