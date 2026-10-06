import AppKit
import Carbon
import XCTest
#if DIRECT_DOWNLOAD
@testable import CopiedDirect
#else
@testable import Copied
#endif

@MainActor
final class GlobalHotkeyTests: XCTestCase {
    func testShortcutRegistersDispatchesAndUnregisters() async throws {
        let manager = GlobalHotkeyManager.shared
        let defaults = UserDefaults.standard
        let oldKeyCode = defaults.object(forKey: "hotkeyKeyCode")
        let oldModifiers = defaults.object(forKey: "hotkeyModifiers2")
        defer {
            manager.unregister()
            defaults.set(oldKeyCode, forKey: "hotkeyKeyCode")
            defaults.set(oldModifiers, forKey: "hotkeyModifiers2")
        }
        manager.keyCode = 80 // F19 avoids the user's default shortcut.
        manager.modifierMask = [.maskControl, .maskShift, .maskAlternate, .maskCommand]
        let triggered = expectation(description: "Carbon hotkey callback")
        manager.register { triggered.fulfill() }
        XCTAssertTrue(manager.isRegistered)

        var event: EventRef?
        XCTAssertEqual(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed),
                                   0, EventAttributes(kEventAttributeUserEvent), &event), noErr)
        let carbonEvent = try XCTUnwrap(event)
        defer { ReleaseEvent(carbonEvent) }
        var hotkeyID = EventHotKeyID(signature: 0x434F5059, id: 1)
        XCTAssertEqual(SetEventParameter(carbonEvent, EventParamName(kEventParamDirectObject),
                                        EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size,
                                        &hotkeyID), noErr)
        XCTAssertEqual(SendEventToEventTarget(carbonEvent, GetApplicationEventTarget()), noErr)
        await fulfillment(of: [triggered], timeout: 2)

        manager.unregister()
        XCTAssertFalse(manager.isRegistered)
        manager.register {}
        XCTAssertTrue(manager.isRegistered)
    }
}
