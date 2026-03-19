import Testing
import SwiftData
import Foundation
@testable import CopiedKit

@Suite("Clipping Model")
struct ClippingModelTests {

    private func makeContext() throws -> ModelContext {
        let container = try CopiedSchema.makeContainer(inMemory: true, cloudSync: false)
        return ModelContext(container)
    }

    @Test("Create text clipping")
    func createTextClipping() throws {
        let ctx = try makeContext()
        let clip = Clipping(text: "Hello world", types: ["public.utf8-plain-text"])
        ctx.insert(clip)
        try ctx.save()

        let fetched = try ctx.fetch(FetchDescriptor<Clipping>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.text == "Hello world")
        #expect(fetched.first?.contentKind == .text)
    }

    @Test("Create URL clipping")
    func createURLClipping() throws {
        let ctx = try makeContext()
        let clip = Clipping(url: "https://example.com")
        ctx.insert(clip)
        try ctx.save()

        let fetched = try ctx.fetch(FetchDescriptor<Clipping>())
        #expect(fetched.first?.contentKind == .link)
        #expect(fetched.first?.url == "https://example.com")
    }

    @Test("Create image clipping")
    func createImageClipping() throws {
        let ctx = try makeContext()
        let clip = Clipping()
        clip.imageData = Data([0x89, 0x50, 0x4E, 0x47]) // PNG header stub
        clip.hasImage = true
        clip.imageByteCount = 4
        clip.imageWidth = 100
        clip.imageHeight = 200
        ctx.insert(clip)
        try ctx.save()

        let fetched = try ctx.fetch(FetchDescriptor<Clipping>())
        #expect(fetched.first?.contentKind == .image)
        #expect(fetched.first?.imageWidth == 100)
    }

    @Test("Display title fallback chain")
    func displayTitle() throws {
        // Title takes priority
        let c1 = Clipping(text: "body", title: "My Title")
        #expect(c1.displayTitle == "My Title")

        // Falls back to text
        let c2 = Clipping(text: "Some text content")
        #expect(c2.displayTitle == "Some text content")

        // Falls back to URL
        let c3 = Clipping(url: "https://example.com")
        #expect(c3.displayTitle == "https://example.com")

        // Falls back to "Image" for image clippings
        let c4 = Clipping()
        c4.hasImage = true
        #expect(c4.displayTitle == "Image")

        // Final fallback
        let c5 = Clipping()
        #expect(c5.displayTitle == "Empty Clipping")
    }

    @Test("Soft delete (trash) and restore")
    func trashAndRestore() throws {
        let ctx = try makeContext()
        let clip = Clipping(text: "deleteme")
        ctx.insert(clip)
        try ctx.save()

        #expect(!clip.isInTrash)

        clip.moveToTrash()
        #expect(clip.isInTrash)
        #expect(clip.deleteDate != nil)

        clip.restore()
        #expect(!clip.isInTrash)
        #expect(clip.deleteDate == nil)
    }

    @Test("Favorite and pin")
    func favoriteAndPin() throws {
        let clip = Clipping(text: "important")
        #expect(!clip.isFavorite)
        #expect(!clip.isPinned)

        clip.isFavorite = true
        clip.isPinned = true
        #expect(clip.isFavorite)
        #expect(clip.isPinned)
    }

    @Test("Filter trashed clippings with predicate")
    func filterTrashed() throws {
        let ctx = try makeContext()

        let active = Clipping(text: "active")
        let trashed = Clipping(text: "trashed")
        trashed.moveToTrash()

        ctx.insert(active)
        ctx.insert(trashed)
        try ctx.save()

        let activePredicate = #Predicate<Clipping> { $0.deleteDate == nil }
        let descriptor = FetchDescriptor<Clipping>(predicate: activePredicate)
        let results = try ctx.fetch(descriptor)

        #expect(results.count == 1)
        #expect(results.first?.text == "active")
    }

    @Test("Sort by addDate descending")
    func sortByDate() throws {
        let ctx = try makeContext()

        let old = Clipping(text: "old")
        old.addDate = Date(timeIntervalSinceNow: -100)
        let recent = Clipping(text: "recent")
        recent.addDate = Date()

        ctx.insert(old)
        ctx.insert(recent)
        try ctx.save()

        let descriptor = FetchDescriptor<Clipping>(
            sortBy: [SortDescriptor(\.addDate, order: .reverse)]
        )
        let results = try ctx.fetch(descriptor)
        #expect(results.first?.text == "recent")
        #expect(results.last?.text == "old")
    }
}
