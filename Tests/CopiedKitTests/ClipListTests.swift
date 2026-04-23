import Testing
import SwiftData
import Foundation
@testable import CopiedKit

@Suite("ClipList Model")
struct ClipListTests {

    private func makeContext() throws -> ModelContext {
        let container = try CopiedSchema.makeContainer(inMemory: true, cloudSync: false)
        return ModelContext(container)
    }

    @Test("Create list with defaults")
    func createList() throws {
        let ctx = try makeContext()
        let list = ClipList(name: "Work", colorHex: 0xFF0000)
        ctx.insert(list)
        try ctx.save()

        let fetched = try ctx.fetch(FetchDescriptor<ClipList>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.name == "Work")
        #expect(fetched.first?.colorHex == 0xFF0000)
    }

    @Test("Assign clipping to list")
    func assignClippingToList() throws {
        let ctx = try makeContext()
        let list = ClipList(name: "Research")
        let clip = Clipping(text: "interesting finding")
        clip.list = list

        ctx.insert(list)
        ctx.insert(clip)
        try ctx.save()

        let fetchedList = try ctx.fetch(FetchDescriptor<ClipList>()).first
        #expect(fetchedList?.clippingCount == 1)
        #expect(fetchedList?.clippings?.first?.text == "interesting finding")
    }

    @Test("Nullify clipping relationship on list delete")
    func deleteListNullifiesClippings() throws {
        let ctx = try makeContext()
        let list = ClipList(name: "Temp")
        let clip = Clipping(text: "orphaned")
        clip.list = list

        ctx.insert(list)
        ctx.insert(clip)
        try ctx.save()

        ctx.delete(list)
        try ctx.save()

        let clips = try ctx.fetch(FetchDescriptor<Clipping>())
        #expect(clips.count == 1)
        #expect(clips.first?.list == nil)
    }

    @Test("Multiple lists with sort order")
    func sortOrder() throws {
        let ctx = try makeContext()

        let work = ClipList(name: "Work")
        work.sortOrder = 0
        let personal = ClipList(name: "Personal")
        personal.sortOrder = 1
        let archive = ClipList(name: "Archive")
        archive.sortOrder = 2

        ctx.insert(work)
        ctx.insert(personal)
        ctx.insert(archive)
        try ctx.save()

        let descriptor = FetchDescriptor<ClipList>(
            sortBy: [SortDescriptor(\.sortOrder)]
        )
        let fetched = try ctx.fetch(descriptor)
        #expect(fetched.map(\.name) == ["Work", "Personal", "Archive"])
    }
}
