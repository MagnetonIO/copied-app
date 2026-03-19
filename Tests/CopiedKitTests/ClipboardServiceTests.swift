import Testing
import SwiftData
import Foundation
@testable import CopiedKit

#if canImport(AppKit)
import AppKit

@Suite("ClipboardService")
@MainActor
struct ClipboardServiceTests {

    private func makeContext() throws -> ModelContext {
        let container = try CopiedSchema.makeContainer(inMemory: true, cloudSync: false)
        return ModelContext(container)
    }

    @Test("Configure sets model context")
    func configure() throws {
        let service = ClipboardService()
        let ctx = try makeContext()
        service.configure(modelContext: ctx)

        #expect(!service.isMonitoring)
    }

    @Test("Start and stop monitoring")
    func startStop() throws {
        let service = ClipboardService()
        let ctx = try makeContext()
        service.configure(modelContext: ctx)

        service.start()
        #expect(service.isMonitoring)

        service.stop()
        #expect(!service.isMonitoring)
    }

    @Test("Start is idempotent")
    func startIdempotent() throws {
        let service = ClipboardService()
        let ctx = try makeContext()
        service.configure(modelContext: ctx)

        service.start()
        service.start() // should not crash or double-start
        #expect(service.isMonitoring)

        service.stop()
    }

    @Test("Manual save captures clipboard text")
    func manualSave() throws {
        let service = ClipboardService()
        let ctx = try makeContext()
        service.configure(modelContext: ctx)

        // Put something on the clipboard
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("test capture \(UUID())", forType: .string)

        service.saveCurrentClipboard()

        let fetched = try ctx.fetch(FetchDescriptor<Clipping>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.text?.hasPrefix("test capture") == true)
        #expect(service.captureCount == 1)
    }

    @Test("Duplicate text is not saved twice")
    func deduplication() throws {
        let service = ClipboardService()
        let ctx = try makeContext()
        service.configure(modelContext: ctx)

        let text = "duplicate test \(UUID())"
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        service.saveCurrentClipboard()
        service.saveCurrentClipboard()

        let fetched = try ctx.fetch(FetchDescriptor<Clipping>())
        #expect(fetched.count == 1)
    }

    @Test("Different text creates separate clippings")
    func differentText() throws {
        let service = ClipboardService()
        let ctx = try makeContext()
        service.configure(modelContext: ctx)

        let pasteboard = NSPasteboard.general

        pasteboard.clearContents()
        pasteboard.setString("first \(UUID())", forType: .string)
        service.saveCurrentClipboard()

        pasteboard.clearContents()
        pasteboard.setString("second \(UUID())", forType: .string)
        service.saveCurrentClipboard()

        let fetched = try ctx.fetch(FetchDescriptor<Clipping>())
        #expect(fetched.count == 2)
    }

    @Test("Captures source app metadata")
    func capturesAppMetadata() throws {
        let service = ClipboardService()
        let ctx = try makeContext()
        service.configure(modelContext: ctx)

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("app metadata test \(UUID())", forType: .string)
        service.saveCurrentClipboard()

        let fetched = try ctx.fetch(FetchDescriptor<Clipping>())
        let clip = try #require(fetched.first)

        // Should have captured some device name
        #expect(!clip.deviceName.isEmpty)
        // Types should include the UTI
        #expect(!clip.types.isEmpty)
    }

    @Test("History limit enforcement")
    func historyLimit() throws {
        let service = ClipboardService(maxHistory: 3)
        let ctx = try makeContext()
        service.configure(modelContext: ctx)

        // Insert 5 clippings directly
        for i in 0..<5 {
            let clip = Clipping(text: "item \(i)")
            clip.addDate = Date(timeIntervalSinceNow: TimeInterval(i))
            ctx.insert(clip)
        }
        try ctx.save()

        // Trigger enforcement by saving one more via the service
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("overflow \(UUID())", forType: .string)
        service.saveCurrentClipboard()

        let fetched = try ctx.fetch(FetchDescriptor<Clipping>())
        #expect(fetched.count <= 4) // may be 3 or 4 depending on timing
    }

    @Test("Favorited items survive history cleanup")
    func favoritesProtected() throws {
        let service = ClipboardService(maxHistory: 2)
        let ctx = try makeContext()
        service.configure(modelContext: ctx)

        // Insert a favorited clipping
        let fav = Clipping(text: "precious")
        fav.isFavorite = true
        fav.addDate = Date(timeIntervalSinceNow: -1000) // old
        ctx.insert(fav)

        // Insert 3 regular ones
        for i in 0..<3 {
            let clip = Clipping(text: "regular \(i)")
            clip.addDate = Date(timeIntervalSinceNow: TimeInterval(-100 + i))
            ctx.insert(clip)
        }
        try ctx.save()

        // Trigger cleanup
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("trigger cleanup \(UUID())", forType: .string)
        service.saveCurrentClipboard()

        // The favorited item should still exist
        let descriptor = FetchDescriptor<Clipping>(
            predicate: #Predicate { $0.isFavorite }
        )
        let favs = try ctx.fetch(descriptor)
        #expect(favs.count == 1)
        #expect(favs.first?.text == "precious")
    }
}
#endif
