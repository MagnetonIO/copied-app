import Testing
import SwiftData
import Foundation
@testable import CopiedKit

#if canImport(AppKit)
import AppKit

/// Automated QA tests that simulate real user workflows.
/// These test the full pipeline: pasteboard → capture → query → verify.
@Suite("QA Integration Tests")
@MainActor
struct QATests {

    private func makeService() throws -> (ClipboardService, ModelContext) {
        let container = try CopiedSchema.makeContainer(inMemory: true, cloudSync: false)
        let ctx = ModelContext(container)
        let service = ClipboardService()
        service.configure(modelContext: ctx)
        return (service, ctx)
    }

    // MARK: - Clipboard Capture Scenarios

    @Test("QA: Copy plain text → appears in history")
    func copyPlainText() throws {
        let (service, ctx) = try makeService()
        let pasteboard = NSPasteboard.general
        let unique = "QA plain text \(UUID())"

        pasteboard.clearContents()
        pasteboard.setString(unique, forType: .string)
        service.saveCurrentClipboard()

        let clips = try ctx.fetch(FetchDescriptor<Clipping>())
        let match = clips.first { $0.text == unique }
        #expect(match != nil, "Copied text should appear in history")
        #expect(match?.contentKind == .text)
        #expect(match?.types.contains("public.utf8-plain-text") == true)
    }

    @Test("QA: Copy URL → captured as link")
    func copyURL() throws {
        let (service, ctx) = try makeService()
        let pasteboard = NSPasteboard.general

        pasteboard.clearContents()
        let url = "https://example.com/\(UUID())"
        pasteboard.setString(url, forType: .URL)
        pasteboard.setString(url, forType: .string)
        service.saveCurrentClipboard()

        let clips = try ctx.fetch(FetchDescriptor<Clipping>())
        let match = clips.first { $0.url == url }
        #expect(match != nil, "URL should be captured")
    }

    @Test("QA: Copy image → captured with dimensions")
    func copyImage() throws {
        let (service, ctx) = try makeService()
        let pasteboard = NSPasteboard.general

        // Create a test image
        let image = NSImage(size: NSSize(width: 64, height: 48))
        image.lockFocus()
        NSColor.red.set()
        NSBezierPath.fill(NSRect(x: 0, y: 0, width: 64, height: 48))
        image.unlockFocus()

        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        service.saveCurrentClipboard()

        let clips = try ctx.fetch(FetchDescriptor<Clipping>())
        let match = clips.first { $0.imageData != nil }
        #expect(match != nil, "Image should be captured")
        #expect(match?.contentKind == .image)
        #expect(match?.imageWidth == 64)
        #expect(match?.imageHeight == 48)
    }

    @Test("QA: Rapid identical copies → only one entry")
    func rapidDuplicates() throws {
        let (service, ctx) = try makeService()
        let pasteboard = NSPasteboard.general
        let text = "rapid dupe \(UUID())"

        for _ in 0..<5 {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            service.saveCurrentClipboard()
        }

        let clips = try ctx.fetch(FetchDescriptor<Clipping>())
        let matches = clips.filter { $0.text == text }
        #expect(matches.count == 1, "Duplicate text should only appear once")
    }

    @Test("QA: Rapid identical screenshots → only one entry")
    func rapidDuplicateImages() throws {
        let (service, ctx) = try makeService()
        let pasteboard = NSPasteboard.general

        let image = NSImage(size: NSSize(width: 100, height: 100))
        image.lockFocus()
        NSColor.blue.set()
        NSBezierPath.fill(NSRect(x: 0, y: 0, width: 100, height: 100))
        image.unlockFocus()

        for _ in 0..<3 {
            pasteboard.clearContents()
            pasteboard.writeObjects([image])
            service.saveCurrentClipboard()
        }

        let clips = try ctx.fetch(FetchDescriptor<Clipping>())
        let imageClips = clips.filter { $0.imageData != nil }
        #expect(imageClips.count == 1, "Duplicate images should only appear once")
    }

    @Test("QA: Different content creates separate entries")
    func differentContent() throws {
        let (service, ctx) = try makeService()
        let pasteboard = NSPasteboard.general

        let items = ["alpha \(UUID())", "beta \(UUID())", "gamma \(UUID())"]
        for item in items {
            pasteboard.clearContents()
            pasteboard.setString(item, forType: .string)
            service.saveCurrentClipboard()
        }

        let clips = try ctx.fetch(FetchDescriptor<Clipping>())
        #expect(clips.count == 3, "Three different texts should create three entries")
    }

    // MARK: - Trash / Restore Workflow

    @Test("QA: Delete and restore clipping")
    func deleteAndRestore() throws {
        let (service, ctx) = try makeService()
        let pasteboard = NSPasteboard.general

        pasteboard.clearContents()
        pasteboard.setString("to delete \(UUID())", forType: .string)
        service.saveCurrentClipboard()

        let clip = try ctx.fetch(FetchDescriptor<Clipping>()).first!

        // Move to trash
        clip.moveToTrash()
        try ctx.save()

        // Verify filtered out of active list
        let activeDescriptor = FetchDescriptor<Clipping>(
            predicate: #Predicate { $0.deleteDate == nil }
        )
        let active = try ctx.fetch(activeDescriptor)
        #expect(active.isEmpty, "Trashed clipping should not appear in active list")

        // Restore
        clip.restore()
        try ctx.save()

        let restored = try ctx.fetch(activeDescriptor)
        #expect(restored.count == 1, "Restored clipping should appear again")
    }

    // MARK: - List Assignment

    @Test("QA: Create list and assign clipping")
    func listAssignment() throws {
        let (service, ctx) = try makeService()
        let pasteboard = NSPasteboard.general

        let list = ClipList(name: "Work")
        ctx.insert(list)

        pasteboard.clearContents()
        pasteboard.setString("work item \(UUID())", forType: .string)
        service.saveCurrentClipboard()

        let clip = try ctx.fetch(FetchDescriptor<Clipping>()).first!
        clip.list = list
        try ctx.save()

        #expect(list.clippingCount == 1)
        #expect(clip.list?.name == "Work")
    }

    // MARK: - Favorites Protection

    @Test("QA: Favorites survive history purge")
    func favoritesSurvivePurge() throws {
        let service = ClipboardService(maxHistory: 2)
        let container = try CopiedSchema.makeContainer(inMemory: true, cloudSync: false)
        let ctx = ModelContext(container)
        service.configure(modelContext: ctx)

        // Add a favorite
        let fav = Clipping(text: "precious \(UUID())")
        fav.isFavorite = true
        fav.addDate = Date(timeIntervalSinceNow: -10000)
        ctx.insert(fav)
        try ctx.save()

        // Fill history past limit
        let pasteboard = NSPasteboard.general
        for i in 0..<5 {
            pasteboard.clearContents()
            pasteboard.setString("overflow \(i) \(UUID())", forType: .string)
            service.saveCurrentClipboard()
        }

        // Verify favorite survived
        let favDescriptor = FetchDescriptor<Clipping>(
            predicate: #Predicate { $0.isFavorite }
        )
        let favs = try ctx.fetch(favDescriptor)
        #expect(favs.count == 1, "Favorite should survive purge")
        #expect(favs.first?.text?.hasPrefix("precious") == true)
    }

    // MARK: - Search

    @Test("QA: Search finds matching clippings")
    func searchFiltering() throws {
        let (_, ctx) = try makeService()

        let clips = [
            Clipping(text: "Swift programming language"),
            Clipping(text: "Python data science"),
            Clipping(text: "Swift concurrency patterns"),
        ]
        for clip in clips { ctx.insert(clip) }
        try ctx.save()

        let all = try ctx.fetch(FetchDescriptor<Clipping>())
        let query = "swift"
        let filtered = all.filter {
            $0.text?.localizedCaseInsensitiveContains(query) == true
        }
        #expect(filtered.count == 2, "Search for 'swift' should match 2 items")
    }

    // MARK: - Copy Back to Clipboard

    @Test("QA: Clicking clipping copies it back to clipboard")
    func copyBack() throws {
        let (service, ctx) = try makeService()
        let pasteboard = NSPasteboard.general
        let original = "copy me back \(UUID())"

        pasteboard.clearContents()
        pasteboard.setString(original, forType: .string)
        service.saveCurrentClipboard()

        // Clear clipboard
        pasteboard.clearContents()
        pasteboard.setString("something else", forType: .string)

        // Simulate clicking the clipping to copy it back
        let clip = try ctx.fetch(FetchDescriptor<Clipping>()).first { $0.text == original }!
        pasteboard.clearContents()
        if let text = clip.text {
            pasteboard.setString(text, forType: .string)
        }

        #expect(pasteboard.string(forType: .string) == original)
    }
}
#endif
