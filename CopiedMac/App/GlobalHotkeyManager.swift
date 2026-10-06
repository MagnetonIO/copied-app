import AppKit
import Carbon

/// Registers a global shortcut without Accessibility access on every channel.
@MainActor
final class GlobalHotkeyManager: NSObject {
    static let shared = GlobalHotkeyManager()

    private var hotkeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    var isRegistered: Bool {
        hotkeyRef != nil
    }

    // Callback
    private static var sharedCallback: (() -> Void)?

    // Shortcut config — defaults to ⌃⇧C (keyCode 8)
    var keyCode: UInt16 {
        get { UInt16(UserDefaults.standard.integer(forKey: "hotkeyKeyCode").nonZeroOr(8)) }
        set { UserDefaults.standard.set(Int(newValue), forKey: "hotkeyKeyCode") }
    }
    var modifierMask: CGEventFlags {
        get {
            let raw = UserDefaults.standard.integer(forKey: "hotkeyModifiers2")
            if raw == 0 { return [.maskControl, .maskShift] }
            return CGEventFlags(rawValue: UInt64(raw))
        }
        set { UserDefaults.standard.set(Int(newValue.rawValue), forKey: "hotkeyModifiers2") }
    }

    private override init() { super.init() }

    func register(callback: @escaping () -> Void) {
        unregister()
        GlobalHotkeyManager.sharedCallback = callback

        registerCarbonHotkey()
    }

    func unregister() {
        if let ref = hotkeyRef { UnregisterEventHotKey(ref); hotkeyRef = nil }
        if let ref = eventHandlerRef { RemoveEventHandler(ref); eventHandlerRef = nil }
        GlobalHotkeyManager.sharedCallback = nil
    }

    // MARK: - Carbon Hotkey

    private func registerCarbonHotkey() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, _, _) -> OSStatus in
                DispatchQueue.main.async {
                    GlobalHotkeyManager.sharedCallback?()
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            &eventHandlerRef
        )
        guard handlerStatus == noErr else {
            logToFile("Could not install Carbon hotkey handler: \(handlerStatus)")
            return
        }

        var carbonMods: UInt32 = 0
        if modifierMask.contains(.maskControl) { carbonMods |= UInt32(controlKey) }
        if modifierMask.contains(.maskShift) { carbonMods |= UInt32(shiftKey) }
        if modifierMask.contains(.maskCommand) { carbonMods |= UInt32(cmdKey) }
        if modifierMask.contains(.maskAlternate) { carbonMods |= UInt32(optionKey) }

        let hotkeyID = EventHotKeyID(signature: 0x434F5059, id: 1)
        let hotkeyStatus = RegisterEventHotKey(
            UInt32(keyCode),
            carbonMods,
            hotkeyID,
            GetApplicationEventTarget(),
            0,
            &hotkeyRef
        )
        if hotkeyStatus != noErr {
            if let ref = eventHandlerRef { RemoveEventHandler(ref); eventHandlerRef = nil }
            logToFile("Could not register Carbon hotkey: \(hotkeyStatus)")
        } else {
            logToFile("Hotkey registered via Carbon (\(shortcutDescription))")
        }
    }

    // MARK: - Description

    var shortcutDescription: String {
        var parts: [String] = []
        if modifierMask.contains(.maskControl) { parts.append("⌃") }
        if modifierMask.contains(.maskShift) { parts.append("⇧") }
        if modifierMask.contains(.maskCommand) { parts.append("⌘") }
        if modifierMask.contains(.maskAlternate) { parts.append("⌥") }
        parts.append(keyName(for: keyCode))
        return parts.joined()
    }

    private func keyName(for code: UInt16) -> String {
        let names: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 31: "O", 32: "U", 34: "I", 35: "P", 37: "L",
            38: "J", 40: "K", 45: "N", 46: "M",
        ]
        return names[code] ?? "Key\(code)"
    }
}

extension GlobalHotkeyManager {
    nonisolated func logToFile(_ msg: String) {
        #if DEBUG
        let entry = "\(Date()): \(msg)\n"
        let path = "/tmp/copied_hotkey.log"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(entry.data(using: .utf8)!)
            handle.closeFile()
        } else {
            try? entry.write(toFile: path, atomically: true, encoding: .utf8)
        }
        #endif
    }
}

private extension Int {
    func nonZeroOr(_ fallback: Int) -> Int {
        self != 0 ? self : fallback
    }
}
