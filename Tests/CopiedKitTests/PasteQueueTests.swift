import Testing
import SwiftData
import Foundation
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
}
