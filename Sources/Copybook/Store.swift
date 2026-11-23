import AppKit
import ImageIO
import Foundation

/// Persists clips as a JSON index plus one folder of raw blobs per clip.
@MainActor
final class Store: ObservableObject {
    @Published private(set) var items: [ClipItem] = []

    let baseURL: URL
    let blobsURL: URL
    private(set) var isFirstLaunch = false

    private var indexURL: URL { baseURL.appendingPathComponent("library.json") }
    private var saveWork: DispatchWorkItem?
    private let io = DispatchQueue(label: "copybook.store.io", qos: .utility)
    private let imageCache = NSCache<NSString, NSImage>()
    private let richCache = NSCache<NSString, NSAttributedString>()

    private struct Snapshot: Codable {
        var version = 1
        var items: [ClipItem]
    }

    init() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // Tests can point the store at a copy of the data (COPYBOOK_DATA_DIR) so they never share the real one.
        if let dir = ProcessInfo.processInfo.environment["COPYBOOK_DATA_DIR"], ProcessInfo.processInfo.environment["COPYBOOK_TEST_DEFAULTS"] != nil {
            baseURL = URL(fileURLWithPath: dir, isDirectory: true)
        } else {
            baseURL = support.appendingPathComponent("Copybook", isDirectory: true)
        }
        blobsURL = baseURL.appendingPathComponent("blobs", isDirectory: true)
        try? fm.createDirectory(at: blobsURL, withIntermediateDirectories: true)
        load()
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else { isFirstLaunch = true; return }
        do {
            let snap = try JSONDecoder().decode(Snapshot.self, from: data)
            items = snap.items.sorted { $0.date > $1.date }
        } catch {
            let backup = baseURL.appendingPathComponent("library-unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: indexURL, to: backup)
            NSLog("Copybook: library unreadable, moved to \(backup.path): \(error)")
        }
    }

    /// Set while everything is being deleted, so nothing is written back to disk.
    private(set) var frozen = false

    func freeze() {
        frozen = true
        saveWork?.cancel()
        io.sync {}   // let any write already in flight finish before the folder is removed
    }

    func scheduleSave() {
        guard !frozen else { return }
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow(async: true) }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    func saveNow(async: Bool = false) {
        guard !frozen else { return }
        let snap = Snapshot(items: items)
        let url = indexURL
        let write = {
            guard let data = try? JSONEncoder().encode(snap) else { return }
            try? data.write(to: url, options: .atomic)
        }
        if async { io.async(execute: write) } else { io.sync(execute: write) }
    }

    // MARK: Blobs

    func folder(for id: UUID) -> URL { blobsURL.appendingPathComponent(id.uuidString, isDirectory: true) }

    func blobURL(_ item: ClipItem, key: String) -> URL? {
        guard let name = item.representations[key] else { return nil }
        return folder(for: item.id).appendingPathComponent(name)
    }

    func data(_ item: ClipItem, key: String) -> Data? {
        guard let url = blobURL(item, key: key) else { return nil }
        return try? Data(contentsOf: url)
    }

    private func writeBlob(_ data: Data, key: String, into item: inout ClipItem) {
        let dir = folder(for: item.id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = item.representations[key] ?? "r\(item.representations.count).bin"
        try? data.write(to: dir.appendingPathComponent(name), options: .atomic)
        item.representations[key] = name
    }

    /// Best full-resolution image data key for an image clip.
    func imageKey(_ item: ClipItem) -> String? {
        ["public.png", "public.tiff", "public.jpeg", "public.heic"].first { item.representations[$0] != nil }
    }

    func thumbnail(_ item: ClipItem) -> NSImage? { cachedImage(item, key: "_thumb") }

    /// A sharp image for cards: decoded from the original at up to `maxPixel` (enough for a
    /// Retina card at any panel size), falling back to the stored thumbnail.
    func displayImage(_ item: ClipItem, maxPixel: Int = 1600) -> NSImage? {
        let ck = "\(item.id.uuidString)display\(maxPixel)" as NSString
        if let img = imageCache.object(forKey: ck) { return img }
        var source: CGImageSource?
        if let key = imageKey(item), let url = blobURL(item, key: key) {
            source = CGImageSourceCreateWithURL(url as CFURL, nil)
        } else if item.kind == .file, let path = item.filePaths?.first, item.filePaths?.count == 1 {
            source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let source, let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else {
            return thumbnail(item)
        }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        imageCache.setObject(img, forKey: ck)
        return img
    }
    func linkImage(_ item: ClipItem) -> NSImage? { cachedImage(item, key: "_linkImage") }

    func fullImage(_ item: ClipItem) -> NSImage? {
        guard let key = imageKey(item), let url = blobURL(item, key: key) else { return thumbnail(item) }
        return NSImage(contentsOf: url)
    }

    private func cachedImage(_ item: ClipItem, key: String) -> NSImage? {
        let ck = "\(item.id.uuidString)\(key)" as NSString
        if let img = imageCache.object(forKey: ck) { return img }
        guard let url = blobURL(item, key: key), let img = NSImage(contentsOf: url) else { return nil }
        imageCache.setObject(img, forKey: ck)
        return img
    }

    /// Rich-text preview with colours removed so it reads on light and dark cards.
    func richPreview(_ item: ClipItem) -> NSAttributedString? {
        guard item.hasRichText else { return nil }
        let ck = item.id.uuidString as NSString
        if let a = richCache.object(forKey: ck) { return a }
        guard let data = data(item, key: "public.rtf"),
              let full = NSAttributedString(rtf: data, documentAttributes: nil) else { return nil }
        let cut = full.attributedSubstring(from: NSRange(location: 0, length: min(full.length, 800)))
        let m = NSMutableAttributedString(attributedString: cut)
        let range = NSRange(location: 0, length: m.length)
        m.removeAttribute(.foregroundColor, range: range)
        m.removeAttribute(.backgroundColor, range: range)
        m.enumerateAttribute(.font, in: range) { value, r, _ in
            guard let f = value as? NSFont else { return }
            let size = min(max(f.pointSize * 0.85, 10), 18)
            m.addAttribute(.font, value: NSFontManager.shared.convert(f, toSize: size), range: r)
        }
        richCache.setObject(m, forKey: ck)
        return m
    }

    // MARK: Mutations

    /// Adds a freshly captured clip. Identical history content is moved to the top instead of duplicated.
    @discardableResult
    func add(_ newItem: ClipItem, blobs: [(String, Data)]) -> (item: ClipItem, isNew: Bool) {
        if let idx = items.firstIndex(where: { $0.contentHash == newItem.contentHash }) {
            var existing = items.remove(at: idx)
            existing.date = Date()
            existing.sourceBundleID = newItem.sourceBundleID ?? existing.sourceBundleID
            existing.sourceAppName = newItem.sourceAppName ?? existing.sourceAppName
            items.insert(existing, at: 0)
            scheduleSave()
            return (existing, false)
        }
        var item = newItem
        for (key, data) in blobs { writeBlob(data, key: key, into: &item) }
        items.insert(item, at: 0)
        scheduleSave()
        return (item, true)
    }

    func mutate(_ id: UUID, _ change: (inout ClipItem) -> Void) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[idx])
        richCache.removeObject(forKey: id.uuidString as NSString)
        scheduleSave()
    }

    func attachBlob(_ data: Data, key: String, to id: UUID, then change: (inout ClipItem) -> Void = { _ in }) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items[idx]
        writeBlob(data, key: key, into: &item)
        change(&item)
        imageCache.removeObject(forKey: "\(id.uuidString)\(key)" as NSString)
        items[idx] = item
        scheduleSave()
    }

    /// Replaces a clip's text after editing; drops rich representations so the edit is what gets pasted.
    func updateText(_ id: UUID, text: String) {
        mutate(id) { item in
            item.text = text
            item.representations = item.representations.filter { $0.key.hasPrefix("_") }
            if item.kind == .link, URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines))?.scheme == nil {
                item.kind = .text
            }
        }
    }

    func delete(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        items.removeAll { ids.contains($0.id) }
        removeFolders(ids)
        scheduleSave()
    }

    private func removeFolders(_ ids: Set<UUID>) {
        let dirs = ids.map(folder(for:))
        io.async { for d in dirs { try? FileManager.default.removeItem(at: d) } }
    }

    func eraseHistory() {
        delete(Set(items.map(\.id)))
    }

    /// Removes clips older than `days` (0 = keep forever).
    func prune(days: Int) {
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        delete(Set(items.filter { $0.date < cutoff }.map(\.id)))
    }

    /// Moves clips to the top (used after pasting).
    func touch(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let set = Set(ids)
        let now = Date()
        for i in items.indices where set.contains(items[i].id) {
            items[i].date = now
        }
        items.sort { $0.date > $1.date }
        scheduleSave()
    }

    func addTextItem(_ text: String) -> ClipItem {
        var item = ClipItem(kind: .text)
        item.text = text
        item.sourceBundleID = Bundle.main.bundleIdentifier
        item.sourceAppName = "Copybook"
        item.contentHash = UUID().uuidString
        items.insert(item, at: 0)
        scheduleSave()
        return item
    }

    /// Apps that appear in history, for the app filter.
    var sourceApps: [(id: String, name: String)] {
        var seen = Set<String>()
        var out: [(String, String)] = []
        for item in items {
            guard let b = item.sourceBundleID, !seen.contains(b) else { continue }
            seen.insert(b)
            out.append((b, item.sourceAppName ?? b))
        }
        return out.sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
    }
}
