import Foundation
import SwiftData
import Observation
import UniformTypeIdentifiers

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Sequential paste queue — cycles through clippings on each paste hotkey press.
@Observable
@MainActor
public final class PasteQueueService {
    public private(set) var queue: [Clipping] = []
    public private(set) var currentIndex: Int = 0
    public var isActive: Bool { !queue.isEmpty }

    public init() {}

    public func load(_ clippings: [Clipping]) {
        queue = clippings
        currentIndex = 0
    }

    public func clear() {
        queue = []
        currentIndex = 0
    }

    public var currentClipping: Clipping? {
        guard currentIndex < queue.count else { return nil }
        return queue[currentIndex]
    }

    /// Paste the current item and advance the index.
    /// iOS note: iOS sandboxing blocks cross-app paste, so this writes to
    /// `UIPasteboard.general` and advances — the user completes the paste
    /// manually in the destination app.
    public func pasteAndAdvance() {
        guard let clipping = currentClipping else { return }

        #if canImport(AppKit)
        writeToPasteboard(clipping)
        simulatePaste()
        #elseif canImport(UIKit)
        writeToPasteboard(clipping)
        #endif

        currentIndex = (currentIndex + 1) % queue.count
    }

    /// Copy the current item to the pasteboard without pasting.
    public func copyCurrentToClipboard() {
        guard let clipping = currentClipping else { return }
        writeToPasteboard(clipping)
    }

    private func writeToPasteboard(_ clipping: Clipping) {
        #if canImport(AppKit)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        if let text = clipping.text {
            pasteboard.setString(text, forType: .string)
        }
        if let url = clipping.url, let nsURL = URL(string: url) {
            pasteboard.setString(nsURL.absoluteString, forType: .URL)
        }
        if let imageData = clipping.imageData {
            pasteboard.setData(imageData, forType: .tiff)
        }
        if let rtfData = clipping.richTextData {
            pasteboard.setData(rtfData, forType: clipping.richTextPasteboardType)
        }
        #elseif canImport(UIKit)
        // One write — each property setter on UIPasteboard bumps `changeCount` and
        // posts `UIPasteboard.changedNotification` separately, which would create
        // a self-capture feedback loop once Phase 4 starts listening for that
        // notification. `setItems` is atomic: one change event, one notification.
        var item: [String: Any] = [:]
        if let text = clipping.text, !text.isEmpty {
            item[UTType.utf8PlainText.identifier] = text
        }
        if let urlString = clipping.url, let url = URL(string: urlString) {
            item[UTType.url.identifier] = url
        }
        if let imageData = clipping.imageData {
            item[UTType.png.identifier] = imageData
        }
        UIPasteboard.general.setItems([item], options: [:])
        #endif
    }

    #if canImport(AppKit)
    private func simulatePaste() {
        let src = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true) // V key
        let keyUp = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
    #endif
}
