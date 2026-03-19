import Foundation
import SwiftData
import Observation

#if canImport(AppKit)
import AppKit
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
    public func pasteAndAdvance() {
        guard let clipping = currentClipping else { return }

        #if canImport(AppKit)
        writeToPasteboard(clipping)
        simulatePaste()
        #endif

        currentIndex = (currentIndex + 1) % queue.count
    }

    /// Copy the current item to the pasteboard without pasting.
    public func copyCurrentToClipboard() {
        guard let clipping = currentClipping else { return }
        #if canImport(AppKit)
        writeToPasteboard(clipping)
        #endif
    }

    #if canImport(AppKit)
    private func writeToPasteboard(_ clipping: Clipping) {
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
            pasteboard.setData(rtfData, forType: .rtf)
        }
    }

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
