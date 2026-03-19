import AppKit
import Carbon

/// Global keyboard shortcut manager. Uses CGEvent tap (HID level) as primary
/// method — this works in fullscreen apps across all Spaces. Falls back to
/// Carbon RegisterEventHotKey if the event tap can't be created.
@MainActor
final class GlobalHotkeyManager: NSObject {
    static let shared = GlobalHotkeyManager()

    // CGEvent tap state
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // Carbon fallback state
    private var hotkeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

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

        // Try CGEvent tap first (works in fullscreen)
        if registerEventTap() {
            logToFile("Hotkey registered via CGEvent tap (\(shortcutDescription))")
            return
        }

        // Fallback to Carbon
        logToFile("CGEvent tap failed, falling back to Carbon hotkey")
        registerCarbonHotkey()
    }

    func unregister() {
        // Clean up event tap — BUG-28 fix: invalidate mach port before release
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            eventTap = nil
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        // Clean up Carbon
        if let ref = hotkeyRef { UnregisterEventHotKey(ref); hotkeyRef = nil }
        if let ref = eventHandlerRef { RemoveEventHandler(ref); eventHandlerRef = nil }
    }

    // MARK: - CGEvent Tap (primary — works in fullscreen)

    private func registerEventTap() -> Bool {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)

        // Use Unmanaged pointer to the CLASS SINGLETON (stable address)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { proxy, type, event, refcon -> Unmanaged<CGEvent>? in
                // Re-enable if system disabled the tap
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let refcon {
                        let mgr = Unmanaged<GlobalHotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                        if let tap = mgr.eventTap {
                            CGEvent.tapEnable(tap: tap, enable: true)
                        }
                    }
                    return Unmanaged.passUnretained(event)
                }

                guard type == .keyDown, let refcon else {
                    return Unmanaged.passUnretained(event)
                }

                let mgr = Unmanaged<GlobalHotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                let eventKeyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

                if eventKeyCode == mgr.keyCode && mgr.flagsMatch(event.flags) {
                    mgr.logToFile("Hotkey triggered! keyCode=\(eventKeyCode)")
                    DispatchQueue.main.async {
                        GlobalHotkeyManager.sharedCallback?()
                    }
                    return nil // consume the event
                }

                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func flagsMatch(_ eventFlags: CGEventFlags) -> Bool {
        let required = modifierMask
        let check: [(CGEventFlags, CGEventFlags)] = [
            (.maskControl, .maskControl),
            (.maskShift, .maskShift),
            (.maskCommand, .maskCommand),
            (.maskAlternate, .maskAlternate),
        ]
        for (flag, _) in check {
            let needsIt = required.contains(flag)
            let hasIt = eventFlags.contains(flag)
            if needsIt != hasIt { return false }
        }
        return true
    }

    // MARK: - Carbon Fallback

    private func registerCarbonHotkey() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
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

        var carbonMods: UInt32 = 0
        if modifierMask.contains(.maskControl) { carbonMods |= UInt32(controlKey) }
        if modifierMask.contains(.maskShift) { carbonMods |= UInt32(shiftKey) }
        if modifierMask.contains(.maskCommand) { carbonMods |= UInt32(cmdKey) }
        if modifierMask.contains(.maskAlternate) { carbonMods |= UInt32(optionKey) }

        var hotkeyID = EventHotKeyID(signature: 0x434F5059, id: 1)
        RegisterEventHotKey(
            UInt32(keyCode),
            carbonMods,
            hotkeyID,
            GetApplicationEventTarget(),
            0,
            &hotkeyRef
        )
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
