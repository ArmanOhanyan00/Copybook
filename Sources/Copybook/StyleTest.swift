import AppKit
import SwiftUI

/// COPYBOOK_PINTEST=style (with COPYBOOK_PINTEST_DIR and COPYBOOK_TEST_DEFAULTS=1): every card shape and the
/// list format, in both layouts, changed live through the settings the way the Settings window changes them.
/// Measures the real cards on screen: their proportions, that they fit, are centred and evenly spaced, that the
/// panel's size limits follow the shape, and that Settings' own buttons drive it. Needs the screen unlocked.
extension LayoutTest {
    private func setStyle(_ format: CardFormat, _ shape: CardShape, vertical: Bool) async {
        if core.prefs.verticalLayout != vertical { core.prefs.verticalLayout = vertical; await wait(1.3) }
        if core.prefs.cardFormat != format { core.prefs.cardFormat = format }
        if core.prefs.cardShape != shape { core.prefs.cardShape = shape }
        await wait(1.3)
        await parkMouse()
    }

    private func ratio(_ r: NSRect) -> CGFloat { r.width / r.height }

    /// What every card shape must satisfy in the current layout.
    private func auditCards(_ label: String, shape: CardShape) {
        let vis = pc.visibleFrame, vertical = core.model.vertical, cs = cards(), size = core.model.cardSize
        check(cs.count >= 2, "\(label): cards on screen (\(cs.count))")
        guard let first = cs.first?.frame else { return }
        let lim = pc.limits(on: pc.panel.screen)
        check(vis.width >= lim.min.width - 1 && vis.width <= lim.max.width + 1 && vis.height >= lim.min.height - 1 && vis.height <= lim.max.height + 1,
              "\(label): panel \(Int(vis.width))×\(Int(vis.height)) is within its limits \(Int(lim.min.width))×\(Int(lim.min.height)) … \(Int(lim.max.width))×\(Int(lim.max.height))")
        check(vis.minX < vis.maxX && NSScreen.screens.contains { $0.visibleFrame.insetBy(dx: -1, dy: -1).contains(vis) }, "\(label): panel fully on screen")
        for c in cs where abs(c.frame.width - size.width) > 1.5 { check(false, "\(label): a \(c.item.kind) card is \(Int(c.frame.width)) wide, model says \(Int(size.width))") }

        if let r = shape.ratio {
            let off = cs.filter { abs(ratio($0.frame) - r) > r * 0.025 }
            check(off.isEmpty, "\(label): every card is \(shape.detail) (\(String(format: "%.3f", ratio(first))) vs \(String(format: "%.3f", r)); off: \(off.count))")
            check(Set(cs.map { Int($0.frame.height.rounded()) }).count == 1, "\(label): all cards are the same height")
        }
        if vertical {
            let inner = vis.width - PanelStyle.verticalInset * 2
            let want = CardStyle.layout(shape: shape, vertical: true, panel: vis.size, chrome: PanelController.chromeHeight,
                                        inset: PanelStyle.verticalInset, verticalHeight: PanelStyle.verticalCardHeight)
            check(want.columns == core.model.columns && want.size == size, "\(label): \(core.model.columns) column(s) of \(Int(size.width))×\(Int(size.height)) as the rules say")
            // Rows: cards that share a top.
            var rows: [[NSRect]] = []
            for c in cs {
                if let last = rows.last, abs(last[0].maxY - c.frame.maxY) < 1 { rows[rows.count - 1].append(c.frame) } else { rows.append([c.frame]) }
            }
            check(rows.dropLast().allSatisfy { $0.count <= core.model.columns }, "\(label): no more than \(core.model.columns) cards in a row")
            if let full = rows.first(where: { $0.count == core.model.columns }) {
                let l = full.map { $0.minX }.min()!, r = full.map { $0.maxX }.max()!
                check(r - l <= inner + 1.5, "\(label): a full row (\(Int(r - l)) pt) fits the \(Int(inner)) pt column")
                check(abs((l - vis.minX) - (vis.maxX - r)) <= 3, "\(label): cards centred (margins \(Int(l - vis.minX)) / \(Int(vis.maxX - r)))")
                // Everything on the left edge lines up, and so does everything in a column.
                check(Set(rows.filter { $0.count > 0 }.map { Int($0[0].minX.rounded()) }).count == 1, "\(label): rows start at the same left edge")
            }
            if core.model.columns > 1 {
                let gaps = rows.flatMap { row in zip(row, row.dropFirst()).map { Int(($1.minX - $0.maxX).rounded()) } }
                check(gaps.allSatisfy { $0 == Int(CardStyle.columnGap) }, "\(label): cards in a row are \(Int(CardStyle.columnGap)) pt apart \(Set(gaps).sorted())")
            }
            if shape != .automatic { check(first.height <= CardStyle.maxColumnHeight + 1, "\(label): card \(Int(first.height)) pt tall is within the \(Int(CardStyle.maxColumnHeight)) pt cap") }
            let wantGaps: Set<Int> = [Int(PanelStyle.cardSpacing), Int(PanelStyle.cardSpacing + 16 + PanelStyle.dayLabelGap + PanelStyle.groupTopPadding)]
            var gaps: [Int] = []
            for (a, b) in zip(rows, rows.dropFirst()) { gaps.append(Int((a[0].minY - b[0].maxY).rounded())) }
            check(gaps.allSatisfy { wantGaps.contains($0) }, "\(label): gaps between rows \(Set(gaps).sorted()) (want \(wantGaps.sorted()))")
        } else {
            let top = vis.maxY - 60 - PanelStyle.topInset, bottom = vis.minY + CardStrip.bottom
            check(first.maxY <= top - 20 && first.minY >= bottom - 1, "\(label): cards sit between the top bar and the action bar (y \(Int(first.minY))…\(Int(first.maxY)), room \(Int(bottom))…\(Int(top - 20)))")
            check(Set(cs.map { Int($0.frame.maxY.rounded()) }).count == 1, "\(label): cards share top and bottom")
            check(abs((first.minX - vis.minX) - CardStrip.leading) <= 1.5, "\(label): first card is \(Int(CardStrip.leading)) pt from the left edge")
            var gaps: [Int] = []
            for (a, b) in zip(cs, cs.dropFirst()) { gaps.append(Int((b.frame.minX - a.frame.maxX).rounded())) }
            check(gaps.allSatisfy { [14, 28].contains($0) }, "\(label): gaps between cards \(Set(gaps).sorted())")
        }
    }

    private func auditList(_ label: String) {
        let vis = pc.visibleFrame, vertical = core.model.vertical, rows = cards(), size = core.model.cardSize, columns = core.model.columns
        check(rows.count >= 3, "\(label): rows on screen (\(rows.count))")
        guard let first = rows.first?.frame else { return }
        let want = CardStyle.listLayout(vertical: vertical, panel: vis.size, rowHeight: PanelStyle.listRowHeight, inset: vertical ? PanelStyle.verticalInset : CardStrip.leading)
        check(want.columns == columns && want.size == size, "\(label): \(columns) column(s) of \(Int(size.width)) pt as the rules say")
        check(rows.allSatisfy { abs($0.frame.height - PanelStyle.listRowHeight) <= 1 }, "\(label): every row is \(Int(PanelStyle.listRowHeight)) pt tall")
        check(Set(rows.map { Int($0.frame.width.rounded()) }).count == 1, "\(label): all rows share a width (\(Int(first.width)))")
        check(first.width <= CardStyle.maxRowWidth + 1 && first.width >= (vertical ? 300 : CardStyle.minRowWidth - 1), "\(label): row width \(Int(first.width)) is between \(Int(CardStyle.minRowWidth)) and \(Int(CardStyle.maxRowWidth))")
        var grid: [[NSRect]] = []
        for c in rows {
            if let last = grid.last, abs(last[0].maxY - c.frame.maxY) < 1 { grid[grid.count - 1].append(c.frame) } else { grid.append([c.frame]) }
        }
        check(grid.dropLast().allSatisfy { $0.count <= columns }, "\(label): no more than \(columns) rows side by side")
        if let full = grid.first(where: { $0.count == columns }) {
            let l = full.map { $0.minX }.min()!, r = full.map { $0.maxX }.max()!
            check(abs((l - vis.minX) - (vis.maxX - r)) <= 3, "\(label): rows centred (margins \(Int(l - vis.minX)) / \(Int(vis.maxX - r)))")
            let side = vertical ? PanelStyle.verticalInset : CardStrip.leading
            check(l - vis.minX >= side - 1.5, "\(label): rows keep \(Int(side)) pt from the edges")
        }
        if columns > 1 {
            let gaps = grid.flatMap { row in zip(row, row.dropFirst()).map { Int(($1.minX - $0.maxX).rounded()) } }
            check(gaps.allSatisfy { $0 == Int(CardStyle.columnGap) }, "\(label): rows side by side are \(Int(CardStyle.columnGap)) pt apart \(Set(gaps).sorted())")
        }
        var gaps: [Int] = []
        for (a, b) in zip(grid, grid.dropFirst()) { gaps.append(Int((a[0].minY - b[0].maxY).rounded())) }
        let ok: Set<Int> = [Int(PanelStyle.listRowSpacing), Int(PanelStyle.listRowSpacing + 16 + PanelStyle.dayLabelGap - 4 + PanelStyle.groupTopPadding)]
        check(gaps.allSatisfy { ok.contains($0) }, "\(label): gaps between rows \(Set(gaps).sorted()) (want \(ok.sorted()))")
        let top = vis.maxY - 60 - PanelStyle.topInset
        check(first.maxY <= top + 1, "\(label): the first row sits below the top bar")
    }

    func styleStage() async {
        core.prefs.verticalLayout = false
        core.prefs.cardFormat = .cards; core.prefs.cardShape = .automatic
        pc.show(); await wait(1.8)
        check(core.visibleItems().count >= 4, "test history has clips (\(core.visibleItems().count))")
        let sv = screenVisible()

        // ---- Pure sizing rules: every shape, both layouts, a spread of panel sizes
        for shape in CardShape.allCases {
            for vertical in [false, true] {
                let panels: [CGSize] = vertical ? [CGSize(width: 400, height: 540), CGSize(width: 420, height: 900), CGSize(width: 600, height: 1000)]
                                                : [CGSize(width: 680, height: 340), CGSize(width: 1400, height: 384), CGSize(width: 1800, height: 464)]
                for p in panels {
                    let s = CardStyle.size(shape: shape, vertical: vertical, panel: p, chrome: PanelController.chromeHeight, inset: PanelStyle.verticalInset, verticalHeight: PanelStyle.verticalCardHeight)
                    let tag = "\(shape.rawValue) \(vertical ? "vertical" : "horizontal") in \(Int(p.width))×\(Int(p.height))"
                    if let r = shape.ratio {
                        check(abs(s.width / s.height - r) <= r * 0.02, "size \(tag): \(Int(s.width))×\(Int(s.height)) keeps \(String(format: "%.2f", r))")
                    }
                    if vertical { check(s.width <= p.width - PanelStyle.verticalInset * 2 + 0.5, "size \(tag): fits the width") }
                    else { check(s.height <= p.height - PanelController.chromeHeight + 0.5 && s.width <= p.width - 46 + 0.5, "size \(tag): fits the panel") }
                }
                if !vertical, let range = CardStyle.heightRange(for: shape), let r = shape.ratio {
                    check(range.lowerBound * r >= CardStyle.minWidth - 1 && range.upperBound * r <= CardStyle.maxWidth + 1 || range.lowerBound == range.upperBound,
                          "range \(shape.rawValue): heights \(Int(range.lowerBound))–\(Int(range.upperBound)) give widths \(Int(range.lowerBound * r))–\(Int(range.upperBound * r))")
                }
            }
        }

        // Every shape starts about equally big, so an upright card is not dwarfed by a wide one.
        let areas = CardShape.allCases.compactMap { s in CardStyle.preferredHeight(for: s).flatMap { h in s.ratio.map { h * h * $0 } } }
        check((areas.max() ?? 0) / max(areas.min() ?? 1, 1) < 1.35, "starting sizes are alike in area (\(areas.map { Int($0 / 1000) }) thousand pt²)")

        // ---- Every shape on screen, both layouts, changed live
        for vertical in [false, true] {
            let layout = vertical ? "vertical" : "horizontal"
            await setStyle(.cards, .automatic, vertical: vertical)
            for shape in CardShape.allCases {
                await setStyle(.cards, shape, vertical: vertical)
                let label = "\(layout) \(shape.rawValue)"
                check(core.model.cardShape == shape && core.model.cardFormat == .cards, "\(label): the panel took the setting")
                check(pc.panel.isVisible && pc.panel.alphaValue > 0.99, "\(label): panel stays open and visible")
                if !vertical, let card = CardStyle.preferredHeight(for: shape) {
                    let lim = pc.limits(on: pc.panel.screen)
                    let want = min(max(PanelController.chromeHeight + card, lim.min.height), lim.max.height)
                    check(abs(pc.visibleFrame.height - want) <= 2, "\(label): the bar opens at \(Int(want)) pt tall (is \(Int(pc.visibleFrame.height))), card \(Int(core.model.cardSize.width))×\(Int(core.model.cardSize.height))")
                }
                auditCards(label, shape: shape)
                capture("style-\(layout)-\(shape.rawValue)")

                // The size limits follow the shape: drag the panel to the smallest and largest it may be.
                let lim = pc.limits(on: pc.panel.screen), m = PanelController.margin
                var f = pc.panel.frame
                if vertical {
                    for w in [lim.min.width, lim.max.width] {
                        f.size.width = w + m * 2; f.origin.x = sv.maxX - 10 - w - m
                        pc.panel.setFrame(f, display: true); await wait(0.7); await parkMouse()
                        auditCards("\(label) at width \(Int(w))", shape: shape)
                    }
                } else {
                    for h in [lim.min.height, lim.max.height] {
                        let bottom = f.minY
                        f.size.height = h + m * 2; f.origin.y = bottom
                        pc.panel.setFrame(f, display: true); await wait(0.7); await parkMouse()
                        auditCards("\(label) at height \(Int(h))", shape: shape)
                    }
                }
                pc.resetPlacement(); await wait(0.9)
            }
        }

        // ---- List format, both layouts
        for vertical in [false, true] {
            let layout = vertical ? "vertical" : "horizontal"
            await setStyle(.list, .automatic, vertical: vertical)
            check(core.model.cardFormat == .list, "\(layout) list: the panel took the setting")
            auditList("\(layout) list")
            capture("style-\(layout)-list")
            // Keyboard: the cursor row stays in view while moving down and back up.
            for _ in 0..<8 { core.moveCursor(1, extend: false, toEnd: false); await wait(0.22) }
            await wait(0.5)
            if let cur = cards().first(where: { $0.item.id == core.model.cursorID }) {
                let v = pc.visibleFrame
                check(cur.frame.minY >= v.minY + PanelStyle.actionBarHeight(vertical: vertical) - 2 && cur.frame.maxY <= v.maxY - 60 - PanelStyle.topInset + 2,
                      "\(layout) list: the cursor row is scrolled into view")
            } else { check(false, "\(layout) list: the cursor row exists after moving down") }
            for _ in 0..<8 { core.moveCursor(-1, extend: false, toEnd: false); await wait(0.12) }
            await wait(0.8)
            // A real click selects the row.
            if let target = cards().dropFirst().first {
                await realClick(cg(NSPoint(x: target.frame.midX, y: target.frame.midY)))
                await wait(0.5)
                check(core.model.cursorID == target.item.id, "\(layout) list: clicking a row selects it")
            }
            await parkMouse()
        }

        // ---- Back to cards: the original look returns exactly
        await setStyle(.cards, .automatic, vertical: false)
        auditCards("back to horizontal automatic", shape: .automatic)

        // ---- A pinned panel keeps its frame when the shape changes
        pc.setPinned(true); await wait(0.5)
        let pinnedFrame = pc.panel.frame
        core.prefs.cardShape = .tall; await wait(1.3)
        check(pc.panel.frame == pinnedFrame, "pinned: the panel kept its exact frame when the shape changed")
        let tall = cards()
        check(!tall.isEmpty && tall.allSatisfy { $0.frame.minY >= pc.visibleFrame.minY && $0.frame.maxY <= pc.visibleFrame.maxY }, "pinned: cards stay inside the pinned panel (\(tall.count))")
        pc.setPinned(false); await wait(0.5)
        core.prefs.cardShape = .automatic; await wait(1.2)

        // ---- Closed panel: a change applies the next time it opens
        pc.hide(animated: false); await wait(0.4)
        core.prefs.cardShape = .portrait; core.prefs.cardFormat = .cards; await wait(0.5)
        pc.show(); await wait(1.6)
        check(core.model.cardShape == .portrait, "changed while closed: the panel opens with the new shape")
        auditCards("opened after a change while closed", shape: .portrait)
        core.prefs.cardShape = .automatic; await wait(1.2)

        // ---- Rapid changes land on the last one
        for s in [CardShape.wide, .tall, .square, .portrait, .landscape] { core.prefs.cardShape = s; await wait(0.12) }
        core.prefs.cardFormat = .list; await wait(0.1); core.prefs.cardFormat = .cards
        await wait(1.6); await parkMouse()
        check(core.model.cardShape == .landscape && core.model.cardFormat == .cards, "rapid changes end on the last choice")
        auditCards("after rapid changes", shape: .landscape)
        core.prefs.cardShape = .automatic; await wait(1.0)

        // ---- Settings: the real buttons
        await settingsStage()
    }

    private func captureSettings(_ name: String) {
        guard let w = NSApp.windows.first(where: { $0.isVisible && $0 !== pc.panel && $0.frame.width > 500 }) else { return }
        let primary = NSScreen.screens[0].frame.height
        let r = w.frame
        let cg = CGRect(x: r.minX, y: primary - r.maxY, width: r.width, height: r.height)
        if let img = CGWindowListCreateImage(cg, .optionIncludingWindow, CGWindowID(w.windowNumber), [.bestResolution]) {
            try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        }
    }

    private func settingsStage() async {
        pc.hide(animated: false)
        core.openSettings(); await wait(1.5)
        captureSettings("settings-general-cards")
        let all = await axAll()
        let labels = all.map { $0.label }
        for shape in CardShape.allCases {
            check(labels.contains("\(shape.detail) card"), "Settings lists the \(shape.rawValue) card shape")
        }
        check(labels.contains(where: { $0 == "Cards" || $0.contains("Cards") }) && labels.contains(where: { $0.contains("List") }), "Settings has the Cards / List switch")
        if let tile = all.first(where: { $0.label == "\(CardShape.wide.detail) card" }) {
            await realClick(CGPoint(x: tile.frame.midX, y: tile.frame.midY)); await wait(0.6)
            check(core.prefs.cardShape == .wide, "clicking the Wide tile sets the shape (\(core.prefs.cardShape))")
        } else { check(false, "found the Wide tile") }
        if let tile = all.first(where: { $0.label == "\(CardShape.tall.detail) card" }) {
            await realClick(CGPoint(x: tile.frame.midX, y: tile.frame.midY)); await wait(0.6)
            check(core.prefs.cardShape == .tall, "clicking the Tall tile sets the shape (\(core.prefs.cardShape))")
        }
        core.prefs.cardShape = .automatic
        core.prefs.cardFormat = .list; await wait(0.8)
        captureSettings("settings-general-list")
        check(!(await axAll()).contains { $0.label == "\(CardShape.wide.detail) card" }, "Settings hides the shape choice while List is selected")
        core.prefs.cardFormat = .cards
    }
}
