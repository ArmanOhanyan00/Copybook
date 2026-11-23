import AppKit
import Foundation

/// Everything Copybook keeps on this Mac, in one place: where it is, what it holds and how big
/// it is. The About page shows this list, and "Delete Everything" removes exactly this list
/// and nothing else.
enum Footprint {
    enum Kind { case clips, settings, cache, temporary, state, app }

    struct Location: Identifiable {
        let url: URL
        let kind: Kind
        let title: String
        let detail: String
        var exists: Bool
        var bytes: Int64 = 0
        var id: String { url.path }
    }

    /// Where things live. `live()` is the real Mac; tests build one around a fake home folder.
    struct Environment {
        var home: URL
        var bundleID: String
        var appName: String
        /// Copies of the app: the running one plus any remembered from earlier launches.
        var appBundles: [URL]
        var tempDir: URL
        var userCacheDir: URL?

        static func live() -> Environment {
            let id = Bundle.main.bundleIdentifier ?? "local.copybook.app"
            var bundles = [Bundle.main.bundleURL]
            bundles.append(contentsOf: Manifest.load().apps.map { URL(fileURLWithPath: $0) })
            var cache: URL?
            var buf = [CChar](repeating: 0, count: 1024)
            if confstr(_CS_DARWIN_USER_CACHE_DIR, &buf, buf.count) > 0 { cache = URL(fileURLWithPath: String(cString: buf)) }
            return Environment(home: FileManager.default.homeDirectoryForCurrentUser, bundleID: id, appName: "Copybook",
                               appBundles: bundles, tempDir: URL(fileURLWithPath: NSTemporaryDirectory()), userCacheDir: cache)
        }

        var library: URL { home.appendingPathComponent("Library", isDirectory: true) }
    }

    // MARK: Manifest: the locations that can vary between Macs and launches

    /// A small file inside Copybook's data folder remembering where the app has run from, so a
    /// copy that was later moved or duplicated is still found when everything is deleted.
    struct Manifest: Codable {
        var apps: [String] = []

        static var url: URL {
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Copybook", isDirectory: true).appendingPathComponent("footprint.json")
        }

        static func load() -> Manifest {
            (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Manifest.self, from: $0) } ?? Manifest()
        }

        /// Called at every launch of the real app (never from test runs).
        static func recordLaunch() {
            var m = load()
            let here = Bundle.main.bundleURL.path
            guard here.hasSuffix(".app"), !m.apps.contains(here) else { return }
            m.apps.append(here)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(m).write(to: url, options: .atomic)
        }
    }

    // MARK: The list

    /// Every location Copybook may have created, whether or not it exists right now.
    static func locations(in env: Environment) -> [Location] {
        let lib = env.library, id = env.bundleID, fm = FileManager.default
        func loc(_ url: URL, _ kind: Kind, _ title: String, _ detail: String) -> Location {
            Location(url: url, kind: kind, title: title, detail: detail, exists: fm.fileExists(atPath: url.path))
        }
        var out: [Location] = [
            loc(lib.appendingPathComponent("Application Support/\(env.appName)", isDirectory: true), .clips,
                "Your clips", "History, images and files you copied"),
            loc(lib.appendingPathComponent("Preferences/\(id).plist"), .settings, "Settings", "Your choices in Copybook"),
            loc(lib.appendingPathComponent("Caches/\(id)", isDirectory: true), .cache, "Cache", "Link previews and thumbnails"),
            loc(lib.appendingPathComponent("Caches/\(env.appName)", isDirectory: true), .cache, "Cache", "Link previews and thumbnails"),
            loc(lib.appendingPathComponent("Saved Application State/\(id).savedState", isDirectory: true), .state, "Window state", "Where windows were last open"),
            loc(lib.appendingPathComponent("HTTPStorages/\(id)", isDirectory: true), .cache, "Network storage", "Cookies for link previews"),
            loc(lib.appendingPathComponent("HTTPStorages/\(id).binarycookies"), .cache, "Network storage", "Cookies for link previews"),
            loc(lib.appendingPathComponent("WebKit/\(id)", isDirectory: true), .cache, "Web content storage", "Used while fetching link previews"),
            loc(lib.appendingPathComponent("Logs/\(env.appName)", isDirectory: true), .temporary, "Logs", "Diagnostic messages"),
            loc(env.tempDir.appendingPathComponent("\(env.appName) Drags", isDirectory: true), .temporary, "Temporary files", "Pictures prepared for dragging"),
        ]
        if let c = env.userCacheDir {
            out.append(loc(c.appendingPathComponent(id, isDirectory: true), .cache, "System cache", "Temporary downloads"))
        }
        var seen = Set<String>()
        for app in env.appBundles where seen.insert(app.standardizedFileURL.path).inserted {
            out.append(loc(app, .app, "The app", "Copybook.app"))
        }
        return out
    }

    /// The same list with sizes, for the About page. Measured off the main thread.
    static func measured(in env: Environment) -> [Location] {
        locations(in: env).compactMap { var l = $0; guard l.exists else { return nil }; l.bytes = size(of: l.url); return l }
    }

    static func size(of url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue { return (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0 }
        var total: Int64 = 0
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        if let e = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: []) {
            for case let f as URL in e {
                let v = try? f.resourceValues(forKeys: Set(keys))
                if v?.isRegularFile == true { total += Int64(v?.totalFileAllocatedSize ?? 0) }
            }
        }
        return total
    }

    // MARK: Safety

    /// A location may only be deleted if it is exactly one of the things Copybook creates: it sits
    /// under a folder we expect, has the name we expect, and is not a folder that merely contains
    /// our things. Anything else is refused, so a wrong path can never take something unrelated.
    static func isSafeToDelete(_ url: URL, kind: Kind, in env: Environment) -> Bool {
        let fm = FileManager.default
        let path = url.standardizedFileURL.path
        guard path.hasPrefix("/"), path.count > 12 else { return false }
        let forbidden: Set<String> = ["/", env.home.path, env.library.path, "/Applications", env.home.appendingPathComponent("Applications").path,
                                      "/System", "/usr", "/Library", "/private", "/var", env.tempDir.path]
        guard !forbidden.contains(path) else { return false }
        // The parent folder is resolved (so /var vs /private/var compare equal); the item itself is
        // never followed, so a symlink is removed as a link and its target is left alone.
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().path
        let name = url.lastPathComponent
        let id = env.bundleID
        func under(_ root: URL?) -> Bool {
            guard let r = root?.resolvingSymlinksInPath().path else { return false }
            return parent == r || parent.hasPrefix(r + "/")
        }
        switch kind {
        case .app:
            guard name.hasSuffix(".app"), url.path != "/", !path.hasPrefix("/System"), !path.hasPrefix("/usr") else { return false }
            let plist = url.appendingPathComponent("Contents/Info.plist")
            guard let info = NSDictionary(contentsOf: plist), info["CFBundleIdentifier"] as? String == id else { return false }
            // Never a symlink standing in for a different app.
            return (try? fm.destinationOfSymbolicLink(atPath: url.path)) == nil
        case .clips:
            return under(env.library.appendingPathComponent("Application Support")) && name == env.appName
        case .settings:
            return under(env.library.appendingPathComponent("Preferences")) && name == "\(id).plist"
        case .state:
            return under(env.library.appendingPathComponent("Saved Application State")) && name == "\(id).savedState"
        case .cache, .temporary:
            let names: Set<String> = [id, "\(id).binarycookies", env.appName, "\(env.appName) Drags"]
            guard names.contains(name) else { return false }
            return under(env.library) || under(env.tempDir) || under(env.userCacheDir)
        }
    }

    // MARK: Removing everything

    struct Plan {
        var items: [Location]          // safe, existing, will be deleted
        var refused: [Location]        // existed but failed the safety check
    }

    static func plan(in env: Environment) -> Plan {
        var items: [Location] = [], refused: [Location] = []
        for l in locations(in: env) where l.exists || (try? l.url.checkResourceIsReachable()) == true {
            if isSafeToDelete(l.url, kind: l.kind, in: env) { items.append(l) } else { refused.append(l) }
        }
        return Plan(items: items, refused: refused)
    }

    struct Outcome {
        var removed: [String] = []
        var failed: [(String, String)] = []
        var deferred: [String] = []     // left for the helper that runs after the app quits
    }

    /// Deletes the plan. Things the running app could recreate while quitting (settings, window state,
    /// caches) and the app itself are left to a helper that runs once the app has exited.
    static func execute(_ plan: Plan, in env: Environment, pid: Int32 = getpid(), realSystemCalls: Bool = true,
                        waitForHelper: Bool = false) -> Outcome {
        var out = Outcome()
        let fm = FileManager.default
        var afterQuit: [URL] = [], apps: [URL] = []
        for item in plan.items {
            switch item.kind {
            case .app:
                apps.append(item.url); afterQuit.append(item.url); out.deferred.append(item.url.path)
            case .settings, .state, .cache:
                // Remove now, and again after quitting in case the app writes them on its way out.
                afterQuit.append(item.url)
                fallthrough
            default:
                do { try fm.removeItem(at: item.url); out.removed.append(item.url.path) }
                catch { if fm.fileExists(atPath: item.url.path) { out.failed.append((item.url.path, error.localizedDescription)) } else { out.removed.append(item.url.path) } }
            }
        }
        runHelper(afterQuit: afterQuit, apps: apps, bundleID: env.bundleID, pid: pid, realSystemCalls: realSystemCalls, wait: waitForHelper)
        return out
    }

    /// A short shell script that waits for the app to quit, then finishes the job. Paths arrive as
    /// separate arguments, never spliced into the script text.
    private static let helperScript = """
    pid="$1"; id="$2"; real="$3"; shift 3
    n=0
    while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 150 ]; do sleep 0.2; n=$((n+1)); done
    if [ "$real" = "1" ]; then
      ls="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
      for p in "$@"; do case "$p" in *.app) "$ls" -u "$p" >/dev/null 2>&1 ;; esac; done
      defaults delete "$id" >/dev/null 2>&1
    fi
    for p in "$@"; do
      case "$p" in ""|"/"|"$HOME") continue ;; esac
      rm -rf -- "$p"
    done
    if [ "$real" = "1" ]; then tccutil reset All "$id" >/dev/null 2>&1; fi
    """

    private static func runHelper(afterQuit: [URL], apps: [URL], bundleID: String, pid: Int32, realSystemCalls: Bool, wait: Bool) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", helperScript, "sh", String(pid), bundleID, realSystemCalls ? "1" : "0"] + afterQuit.map(\.path)
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        if wait { p.waitUntilExit() }
    }

    // MARK: Display

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func abbreviated(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }
}
