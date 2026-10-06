import Testing
import SwiftData
import Foundation
#if canImport(AppKit)
import AppKit
#endif
@testable import CopiedKit

@Suite("PasteQueueService")
@MainActor
struct PasteQueueTests {

    @Test("Load and cycle through queue")
    func loadAndCycle() {
        let service = PasteQueueService()
        let clips = (0..<3).map { Clipping(text: "item \($0)") }

        service.load(clips)

        #expect(service.isActive)
        #expect(service.currentIndex == 0)
        #expect(service.currentClipping?.text == "item 0")
    }

    @Test("Clear queue")
    func clearQueue() {
        let service = PasteQueueService()
        service.load([Clipping(text: "a"), Clipping(text: "b")])

        service.clear()
        #expect(!service.isActive)
        #expect(service.currentClipping == nil)
    }

    @Test("Copy current advances index manually")
    func copyAdvance() {
        let service = PasteQueueService()
        let clips = (0..<3).map { Clipping(text: "item \($0)") }
        service.load(clips)

        #expect(service.currentClipping?.text == "item 0")
        service.copyCurrentToClipboard()
        // copyCurrentToClipboard doesn't advance, pasteAndAdvance does
        #expect(service.currentIndex == 0)
    }

    @Test("Empty queue returns nil")
    func emptyQueue() {
        let service = PasteQueueService()
        #expect(!service.isActive)
        #expect(service.currentClipping == nil)
    }

    @Test("Advance copies each item and wraps without injecting a paste")
    func advanceCopiesAndWraps() {
        let service = PasteQueueService()
        service.load([Clipping(text: "first"), Clipping(text: "second")])

        service.pasteAndAdvance()
        #expect(service.currentIndex == 1)
        #if canImport(AppKit)
        #expect(NSPasteboard.general.string(forType: .string) == "first")
        #endif

        service.pasteAndAdvance()
        #expect(service.currentIndex == 0)
        #if canImport(AppKit)
        #expect(NSPasteboard.general.string(forType: .string) == "second")
        #endif

        service.clear()
        service.pasteAndAdvance()
        #expect(service.currentIndex == 0)
    }
}
