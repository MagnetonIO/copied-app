import AppKit
import SwiftUI
import SwiftData
import XCTest
import CopiedKit
@testable import Copied

@MainActor
final class MainWindowKeyboardNavigationTests: XCTestCase {
    func testArrowNavigationKeepsSelectedRowVisiblePastFirstPage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CopiedKeyboardTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = ModelConfiguration(url: directory.appendingPathComponent("library.store"), cloudKitDatabase: .none)
        let container = try ModelContainer(for: Schema(CopiedSchema.models), configurations: [config])
        let context = container.mainContext
        let count = 200
        let now = Date()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 512, pixelsHigh: 512,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let pixels = try XCTUnwrap(bitmap.bitmapData)
        for offset in 0..<(bitmap.bytesPerRow * bitmap.pixelsHigh) {
            pixels[offset] = offset.isMultiple(of: 4) ? 255 : UInt8(truncatingIfNeeded: offset &* 73 ^ (offset >> 8))
        }
        let image = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        for index in 0..<count {
            let title = index.isMultiple(of: 3)
                ? "Clipping \(index): a longer title that wraps onto a second line in the clippings column"
                : "Clipping \(index)"
            let clipping = Clipping(text: index.isMultiple(of: 5) ? nil : title)
            if index.isMultiple(of: 5) {
                clipping.hasImage = true
                clipping.imageData = image
            }
            clipping.addDate = now.addingTimeInterval(-Double(index))
            clipping.appName = "Test Source"
            context.insert(clipping)
        }
        try context.save()
        let root = MainWindowView()
        .environment(ClipboardService())
        .environment(AppState())
        .environment(SyncMonitor())
        .environment(SyncTicker.shared)
        .modelContainer(container)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 800),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root)
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)

        let table = try await waitForTable(in: window, rowCount: count)
        XCTAssertTrue(window.makeFirstResponder(table))
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        for expectedRow in 1..<150 {
            let oldOrigin = table.visibleRect.minY
            try await sendArrow(.down, in: window)
            XCTAssertEqual(table.selectedRow, expectedRow)
            assertSelectedRowVisible(table, expectedRow: expectedRow)
            let maximumStep = max(table.rect(ofRow: expectedRow).height, table.rect(ofRow: expectedRow - 1).height)
                + table.intercellSpacing.height + 2
            XCTAssertLessThanOrEqual(abs(table.visibleRect.minY - oldOrigin), maximumStep,
                                     "Keyboard scrolling jumped by more than one row at \(expectedRow)")
        }
        for expectedRow in stride(from: 148, through: 0, by: -1) {
            let oldOrigin = table.visibleRect.minY
            try await sendArrow(.up, in: window)
            XCTAssertEqual(table.selectedRow, expectedRow)
            assertSelectedRowVisible(table, expectedRow: expectedRow)
            let maximumStep = max(table.rect(ofRow: expectedRow).height, table.rect(ofRow: expectedRow + 1).height)
                + table.intercellSpacing.height + (expectedRow == 0 ? 18 : 2)
            XCTAssertLessThanOrEqual(abs(table.visibleRect.minY - oldOrigin), maximumStep,
                                     "Keyboard scrolling jumped by more than one row at \(expectedRow)")
        }
    }

    private enum Arrow { case up, down }

    private func sendArrow(_ arrow: Arrow, in window: NSWindow) async throws {
        let isDown = arrow == .down
        let character = String(UnicodeScalar(isDown ? NSDownArrowFunctionKey : NSUpArrowFunctionKey)!)
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: character, charactersIgnoringModifiers: character,
            isARepeat: true, keyCode: isDown ? 125 : 126
        ))
        window.sendEvent(event)
        // Allow SwiftUI to apply selection and row-height changes before
        // checking the row geometry used by keyboard scroll-to-visible.
        try await Task.sleep(for: .milliseconds(25))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    private func assertSelectedRowVisible(
        _ table: NSTableView, expectedRow: Int,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let row = table.rect(ofRow: expectedRow)
        let viewport = table.visibleRect.insetBy(dx: 0, dy: -1)
        XCTAssertGreaterThanOrEqual(row.minY, viewport.minY, "Selected row is above the viewport", file: file, line: line)
        XCTAssertLessThanOrEqual(row.maxY, viewport.maxY, "Selected row is below the viewport", file: file, line: line)
    }

    private func waitForTable(in window: NSWindow, rowCount: Int) async throws -> NSTableView {
        for _ in 0..<100 {
            window.contentView?.layoutSubtreeIfNeeded()
            if let table = findTable(in: window.contentView, rowCount: rowCount) { return table }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw XCTUnwrapError.missingTable
    }

    private func findTable(in view: NSView?, rowCount: Int) -> NSTableView? {
        guard let view else { return nil }
        if let table = view as? NSTableView, table.numberOfRows == rowCount { return table }
        return view.subviews.lazy.compactMap { self.findTable(in: $0, rowCount: rowCount) }.first
    }

    private enum XCTUnwrapError: Error { case missingTable }
}
