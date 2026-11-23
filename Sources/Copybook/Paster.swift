import AppKit
import ApplicationServices
import Carbon

/// Writes clips back to the pasteboard and (optionally) presses ⌘V in the frontmost app.
@MainActor
enum Paster {
    static var isTrusted: Bool { AXIsProcessTrusted() }
    /// Set by the self-test: everything runs except the synthetic ⌘V keystroke.
    static var dryRun = false

    /// Only ever called from a button the user pressed: registers Copybook in the
    /// Accessibility list and opens that pane. Never called automatically.
    static func requestTrustFromUser() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary) // adds Copybook to the list
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Returns the pasteboard's new changeCount so the monitor can ignore it.
    @discardableResult
    static func write(_ items: [ClipItem], store: Store, plain: Bool) -> Int {
        let pb = NSPasteboard.general
        pb.clearContents()
        if items.count > 1, items.allSatisfy({ $0.kind.isTextual }) {
            pb.setString(items.compactMap(\.text).joined(separator: "\n"), forType: .string)
        } else {
            pb.writeObjects(items.flatMap { writers(for: $0, store: store, plain: plain) })
        }
        return pb.changeCount
    }

    /// Standard formats other apps understand. App-private markers (such as Chromium's
    /// source tokens) are left out of drags: a browser seeing its own stale token rejects the drop.
    static let portableTypes: Set<String> = [
        "public.utf8-plain-text", "public.utf16-plain-text", "public.rtf", "public.html", "com.apple.flat-rtfd",
        "public.url", "public.png", "public.tiff", "public.jpeg", "public.heic", "com.compuserve.gif", "com.adobe.pdf",
    ]

    /// What a card puts on the drag pasteboard.
    static func dragWriters(for item: ClipItem, store: Store) -> [NSPasteboardWriting] {
        switch item.kind {
        case .file:
            return (item.filePaths ?? []).map { URL(fileURLWithPath: $0) as NSURL }
        case .link:
            let p = NSPasteboardItem()
            if let url = item.linkURL { p.setString(url.absoluteString, forType: .URL) }
            p.setString(item.text ?? "", forType: .string)
            if let title = item.linkTitle { p.setString(title, forType: .init("public.url-name")) }
            return [p]
        default:
            let p = NSPasteboardItem()
            for key in item.representations.keys where portableTypes.contains(key) {
                if let d = store.data(item, key: key) { p.setData(d, forType: .init(key)) }
            }
            if let t = item.text, !p.types.contains(.string) { p.setString(t, forType: .string) }
            if item.kind == .image, p.types.isEmpty, let thumb = store.data(item, key: "_thumb") { p.setData(thumb, forType: .png) }
            // Browsers, chat apps and upload areas only take a dropped image as a file,
            // so images also travel as a temporary PNG file alongside the image data.
            if item.kind == .image, let file = dragFile(for: item, store: store) {
                p.setString(file.absoluteString, forType: .fileURL)
            }
            return [p]
        }
    }

    /// Writes an image clip to a temporary PNG for dragging (reused while it exists).
    static func dragFile(for item: ClipItem, store: Store) -> URL? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Copybook Drags", isDirectory: true)
            .appendingPathComponent(item.id.uuidString, isDirectory: true)
        var name = (item.title?.isEmpty == false ? item.title! : "Image")
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        if !name.lowercased().hasSuffix(".png") { name += ".png" }
        let url = dir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        guard let key = store.imageKey(item) ?? (item.hasThumbnail ? "_thumb" : nil),
              let data = store.data(item, key: key) else { return nil }
        let png: Data?
        if key == "public.png" || key == "_thumb" {
            png = data
        } else {
            png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
        }
        guard let png else { return nil }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try png.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    static func writers(for item: ClipItem, store: Store, plain: Bool) -> [NSPasteboardWriting] {
        if item.kind == .file {
            let paths = item.filePaths ?? []
            if plain {
                let p = NSPasteboardItem()
                p.setString(paths.joined(separator: "\n"), forType: .string)
                return [p]
            }
            return paths.map { URL(fileURLWithPath: $0) as NSURL }
        }
        let p = NSPasteboardItem()
        if plain, let t = item.text {
            p.setString(t, forType: .string)
            return [p]
        }
        var wrote = false
        for key in item.representations.keys where !key.hasPrefix("_") {
            if let d = store.data(item, key: key) {
                p.setData(d, forType: .init(key))
                wrote = true
            }
        }
        if let t = item.text, !(p.types.contains(.string)) {
            p.setString(t, forType: .string)
            wrote = true
        }
        if !wrote, item.kind == .image, let thumb = store.data(item, key: "_thumb") {
            p.setData(thumb, forType: .png)
        }
        return [p]
    }

    /// Synthesises ⌘V. Requires Accessibility permission.
    static func sendCommandV() {
        guard !dryRun else { return }
        let src = CGEventSource(stateID: .combinedSessionState)
        let v = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
