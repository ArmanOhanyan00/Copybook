import AppKit
import Foundation

/// Debug aid (COPYBOOK_FOOTPRINTTEST=<dir>): runs the "Delete Everything" machinery against a
/// made-up home folder, never the real one. It checks that everything Copybook creates is found
/// and removed, and that look-alikes, other apps' files and symlink targets are left alone.
@MainActor
enum FootprintTest {
    static func run(dir: String) {
        var log: [String] = []
        var failures = 0
        func check(_ ok: Bool, _ msg: String) { log.append((ok ? "ok    " : "FAIL  ") + msg); if !ok { failures += 1 } }

        let fm = FileManager.default
        let root = URL(fileURLWithPath: dir).appendingPathComponent("fake", isDirectory: true)
        try? fm.removeItem(at: root)
        func make(_ path: String, _ text: String = "x") {
            let u = root.appendingPathComponent(path)
            try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: u, atomically: true, encoding: .utf8)
        }
        func app(_ path: String, id: String) {
            make("\(path)/Contents/Info.plist", "")
            let info = ["CFBundleIdentifier": id, "CFBundleName": "Copybook"] as NSDictionary
            info.write(to: root.appendingPathComponent("\(path)/Contents/Info.plist"), atomically: true)
            make("\(path)/Contents/MacOS/Copybook", "binary")
        }
        func exists(_ path: String) -> Bool {
            (try? fm.attributesOfItem(atPath: root.appendingPathComponent(path).path)) != nil
        }

        let id = "local.copybook.app"
        let home = root.appendingPathComponent("home", isDirectory: true)
        // ---- Everything Copybook creates
        make("home/Library/Application Support/Copybook/library.json", "{}")
        make("home/Library/Application Support/Copybook/blobs/a/b.bin", String(repeating: "z", count: 5000))
        make("home/Library/Application Support/Copybook/footprint.json", "{}")
        make("home/Library/Preferences/\(id).plist")
        make("home/Library/Caches/\(id)/fsCachedData/1")
        make("home/Library/Saved Application State/\(id).savedState/windows.plist")
        make("home/Library/HTTPStorages/\(id)/x")
        make("home/Library/HTTPStorages/\(id).binarycookies")
        make("home/Library/WebKit/\(id)/y")
        make("home/Library/Logs/Copybook/z.log")
        make("tmp/Copybook Drags/ABC/Image.png")
        make("syscache/\(id)/c")
        app("home/Applications/Copybook.app", id: id)
        app("Elsewhere/Copybook.app", id: id)               // an older copy, remembered in the manifest
        // ---- Things that must NOT be touched
        make("home/Library/Application Support/CopybookOther/keep.txt")
        make("home/Library/Application Support/Other/keep.txt")
        make("home/Library/Caches/com.other.app/keep.txt")
        make("home/Library/Preferences/other.plist")
        make("home/Library/Preferences/\(id).plist.keep")
        make("tmp/keep.txt")
        make("syscache/com.other/keep.txt")
        make("home/Documents/Copybook/my-notes.txt")        // a user folder that happens to share the name
        app("Decoy/Copybook.app", id: "com.someone.else")   // same file name, different app
        make("Outside/precious.txt", "do not delete")
        try? fm.createSymbolicLink(at: root.appendingPathComponent("home/Library/Caches/Copybook"),
                                   withDestinationURL: root.appendingPathComponent("Outside"))

        let env = Footprint.Environment(
            home: home, bundleID: id, appName: "Copybook",
            appBundles: [root.appendingPathComponent("home/Applications/Copybook.app"),
                         root.appendingPathComponent("Elsewhere/Copybook.app"),
                         root.appendingPathComponent("Decoy/Copybook.app"),
                         root.appendingPathComponent("home/Applications/Gone.app")],   // remembered but already deleted
            tempDir: root.appendingPathComponent("tmp", isDirectory: true),
            userCacheDir: root.appendingPathComponent("syscache", isDirectory: true))

        // ---- The plan
        let plan = Footprint.plan(in: env)
        let planned = Set(plan.items.map { $0.url.path.replacingOccurrences(of: root.path + "/", with: "") })
        let expect = ["home/Library/Application Support/Copybook", "home/Library/Preferences/\(id).plist", "home/Library/Caches/\(id)",
                      "home/Library/Caches/Copybook", "home/Library/Saved Application State/\(id).savedState", "home/Library/HTTPStorages/\(id)",
                      "home/Library/HTTPStorages/\(id).binarycookies", "home/Library/WebKit/\(id)", "home/Library/Logs/Copybook",
                      "tmp/Copybook Drags", "syscache/\(id)", "home/Applications/Copybook.app", "Elsewhere/Copybook.app"]
        check(planned == Set(expect), "plan lists exactly Copybook's own \(expect.count) locations (got \(planned.count))")
        check(!planned.contains("Decoy/Copybook.app"), "a same-named app with a different identity is not planned")
        check(plan.refused.contains { $0.url.path.hasSuffix("Decoy/Copybook.app") }, "…and is reported as refused")
        check(!planned.contains("home/Applications/Gone.app"), "an app that no longer exists is not planned")
        let summary = AppCore.shared.deleteSummary(plan: plan)
        check(summary.contains("permanently deletes") && summary.contains("can’t be undone") && summary.contains("Copybook.app"), "the confirmation names the app and says it can't be undone")
        let alert = AppCore.shared.makeDeleteAlert(plan: plan)
        check(alert.buttons.map(\.title) == ["Cancel", "Delete Everything"], "the dialog offers Cancel first, then Delete Everything")
        check(alert.buttons[0].keyEquivalent == "\r" && alert.buttons[1].keyEquivalent.isEmpty, "Return means Cancel; deleting needs a deliberate click")
        check(alert.alertStyle == .critical && alert.buttons[1].hasDestructiveAction, "it is styled as a critical, destructive action")
        let measured = Footprint.measured(in: env)
        check(measured.contains { $0.kind == .clips && $0.bytes > 0 }, "sizes are measured (clips: \(Footprint.format(measured.first { $0.kind == .clips }?.bytes ?? 0)))")

        // ---- Safety rules, tried directly
        func safe(_ path: String, _ kind: Footprint.Kind) -> Bool { Footprint.isSafeToDelete(URL(fileURLWithPath: path), kind: kind, in: env) }
        let h = home.path
        check(!safe(h, .clips) && !safe("/", .clips) && !safe("\(h)/Library", .clips) && !safe("\(h)/Library/Application Support", .clips), "never the home folder, Library, or a folder that merely contains ours")
        check(!safe("\(h)/Library/Application Support/Other", .clips), "wrong name under the right folder is refused")
        check(!safe("\(h)/Library/Application Support/Copybook/../Other", .clips), "a path that climbs out with .. is refused")
        check(!safe("\(h)/Documents/Copybook", .clips), "the right name under the wrong folder is refused")
        check(!safe("\(h)/Library/Caches/com.apple.Safari", .cache), "another app's cache is refused")
        check(!safe(env.tempDir.path, .temporary) && !safe(h + "/Applications", .app), "the temp folder and the Applications folder are never deleted")
        check(!safe("\(h)/Applications/Copybook", .app) && !safe("/System/Applications/Calculator.app", .app), "an app must be a .app with our identity")
        check(!safe("/Applications/Safari.app", .app), "a real other app is refused")

        // ---- Run it for real, on the fake home
        let outcome = Footprint.execute(plan, in: env, pid: 999_999, realSystemCalls: false, waitForHelper: true)
        check(outcome.failed.isEmpty, "nothing failed to delete (\(outcome.failed.map { $0.0 }))")
        for gone in expect { check(!exists(gone), "removed: \(gone)") }
        // The clip folder's own manifest went with it.
        check(!exists("home/Library/Application Support/Copybook/footprint.json"), "removed: the footprint manifest inside the data folder")
        // ---- And the bystanders are intact
        for keep in ["home/Library/Application Support/CopybookOther/keep.txt", "home/Library/Application Support/Other/keep.txt",
                     "home/Library/Caches/com.other.app/keep.txt", "home/Library/Preferences/other.plist", "home/Library/Preferences/\(id).plist.keep",
                     "tmp/keep.txt", "syscache/com.other/keep.txt", "home/Documents/Copybook/my-notes.txt", "Decoy/Copybook.app/Contents/Info.plist",
                     "Outside/precious.txt", "home/Library", "home", "tmp"] {
            check(exists(keep), "kept: \(keep)")
        }
        check((try? String(contentsOf: root.appendingPathComponent("Outside/precious.txt"))) == "do not delete", "a symlink named like our cache was removed without touching what it pointed at")

        // Read-only preview of what Delete Everything would remove on the real Mac (nothing is deleted).
        if ProcessInfo.processInfo.environment["COPYBOOK_FOOTPRINT_PREVIEW"] != nil {
            let live = Footprint.Environment.live()
            let real = Footprint.plan(in: live)
            log.append("")
            log.append("LIVE PLAN (read-only): \(real.items.count) items")
            for i in real.items { log.append("  would delete [\(i.kind)] \(i.url.path)  \(Footprint.format(Footprint.size(of: i.url)))") }
            for r in real.refused { log.append("  REFUSED [\(r.kind)] \(r.url.path)") }
        }
        log.append("")
        log.append("RESULT: \(failures == 0 ? "all checks passed" : "\(failures) FAILED")")
        try? log.joined(separator: "\n").write(toFile: dir + "/footprinttest.log", atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }
}
