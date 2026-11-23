import AppKit
import Carbon

struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32 // Carbon modifier mask
    var key: String

    static let defaultActivate = Shortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey), key: "V")
    static let defaultStack = Shortcut(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(cmdKey | shiftKey), key: "C")
    static let defaultPickColor = Shortcut(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(cmdKey | shiftKey | controlKey), key: "C")

    init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    init?(event: NSEvent) {
        var m: UInt32 = 0
        let f = event.modifierFlags
        if f.contains(.command) { m |= UInt32(cmdKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.control) { m |= UInt32(controlKey) }
        let isFunctionKey = (96...122).contains(Int(event.keyCode))
        guard m != 0 || isFunctionKey else { return nil }
        keyCode = UInt32(event.keyCode)
        modifiers = m
        key = Shortcut.keyName(event)
    }

    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + key
    }

    static func keyName(_ e: NSEvent) -> String {
        switch Int(e.keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default:
            return (e.charactersIgnoringModifiers ?? "?").uppercased()
        }
    }
}

/// System-wide hotkeys via Carbon's RegisterEventHotKey (no special permission needed).
final class HotKeyCenter {
    static let shared = HotKeyCenter()
    private var refs: [UInt32: EventHotKeyRef] = [:]
    fileprivate var handlers: [UInt32: () -> Void] = [:]
    private var installed = false

    private func install() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { HotKeyCenter.shared.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }

    func register(id: UInt32, shortcut: Shortcut?, handler: @escaping () -> Void) {
        install()
        unregister(id: id)
        handlers[id] = handler
        guard let s = shortcut else { return }
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x4350_4259), id: id) // 'CPBY'
        let status = RegisterEventHotKey(s.keyCode, s.modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref { refs[id] = ref } else { NSLog("Copybook: could not register hotkey \(s.display) (\(status))") }
    }

    func unregister(id: UInt32) {
        if let r = refs.removeValue(forKey: id) { UnregisterEventHotKey(r) }
    }

    func unregisterAll() {
        for id in Array(refs.keys) { unregister(id: id) }
    }
}
