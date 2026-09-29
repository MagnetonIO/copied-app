import AppKit
import SwiftUI
import XCTest
@testable import Copied

@MainActor
final class MainWindowCopyCommandTests: XCTestCase {
    func testNativeCopyCommandCopiesSelectedClipping() async throws {
        var copyCount = 0
        let window = makeWindow(canCopy: true) { copyCount += 1 }
        defer { window.close() }
        let table = try await focusList(in: window)
        XCTAssertTrue(window.makeFirstResponder(table))

        XCTAssertTrue(table.tryToPerform(#selector(NSText.copy(_:)), with: nil))
        XCTAssertEqual(copyCount, 1)
    }

    func testControlCCopiesSelectedClipping() async throws {
        var copyCount = 0
        let window = makeWindow(canCopy: true) { copyCount += 1 }
        defer { window.close() }
        let table = try await focusList(in: window)
        XCTAssertTrue(window.makeFirstResponder(table))
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .control,
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "\u{3}", charactersIgnoringModifiers: "c",
            isARepeat: false, keyCode: 8
        ))

        window.sendEvent(event)
        XCTAssertEqual(copyCount, 1)
    }

    func testCopyDoesNotCopyAClippingWhenSelectionIsEmpty() async throws {
        var copyCount = 0
        let window = makeWindow(canCopy: false) { copyCount += 1 }
        defer { window.close() }
        let table = try await focusList(in: window)
        XCTAssertTrue(window.makeFirstResponder(table))

        _ = table.tryToPerform(#selector(NSText.copy(_:)), with: nil)
        XCTAssertEqual(copyCount, 0)
    }

    func testCopyInTextFieldKeepsNativeTextSelection() async throws {
        var copyCount = 0
        let window = makeWindow(canCopy: true) { copyCount += 1 }
        defer { window.close() }
        _ = try await focusList(in: window)
        let field = NSTextField(string: "search query")
        field.frame = NSRect(x: 0, y: 0, width: 200, height: 24)
        window.contentView?.addSubview(field)
        field.selectText(nil)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: 0, length: 6))

        XCTAssertTrue(editor.tryToPerform(#selector(NSText.copy(_:)), with: nil))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "search")
        XCTAssertEqual(copyCount, 0)
    }

    private func makeWindow(canCopy: Bool, copy: @escaping () -> Void) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView:
            List(selection: .constant(Set(canCopy ? [1] : []))) {
                Text("Selected clipping").tag(1)
            }
            .modifier(MainWindowCopyCommands(canCopy: canCopy, copy: copy))
        )
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func focusList(in window: NSWindow) async throws -> NSTableView {
        for _ in 0..<20 {
            window.contentView?.layoutSubtreeIfNeeded()
            if let table = findTable(in: window.contentView) { return table }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw XCTUnwrapError.missingList
    }

    private func findTable(in view: NSView?) -> NSTableView? {
        guard let view else { return nil }
        if let table = view as? NSTableView { return table }
        return view.subviews.lazy.compactMap { self.findTable(in: $0) }.first
    }

    private enum XCTUnwrapError: Error {
        case missingList
    }
}
