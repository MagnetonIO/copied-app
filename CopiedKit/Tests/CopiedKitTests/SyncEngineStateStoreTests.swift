import Foundation
import Testing
@testable import CopiedKit

@Suite("Sync engine state persistence")
struct SyncEngineStateStoreTests {
    private struct State: Codable, Sendable {
        var records: [String: Data] = [:]
        var listReferences: [String: String] = [:]
        var token: Data?
        var seeded = false
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("CopiedSyncStateTests-\(UUID().uuidString)")
            .appendingPathComponent("state.json")
    }

    @Test("Snapshots wait for an in-progress state mutation")
    func snapshotWaitsForMutation() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = SyncEngineStateStore(fileURL: url, initialState: State())
        let updating = DispatchSemaphore(value: 0)
        let releaseUpdate = DispatchSemaphore(value: 0)
        let reading = DispatchSemaphore(value: 0)
        let readFinished = DispatchSemaphore(value: 0)
        let jobs = DispatchGroup()

        DispatchQueue.global().async(group: jobs) {
            store.update {
                updating.signal()
                _ = releaseUpdate.wait(timeout: .now() + 5)
                $0.records["record"] = Data([1])
            }
        }
        #expect(updating.wait(timeout: .now() + 5) == .success)
        DispatchQueue.global().async(group: jobs) {
            reading.signal()
            _ = store.read { $0.records }
            readFinished.signal()
        }
        #expect(reading.wait(timeout: .now() + 5) == .success)
        let completedDuringMutation = readFinished.wait(timeout: .now() + 0.1)
        releaseUpdate.signal()
        #expect(jobs.wait(timeout: .now() + 5) == .success)
        store.flush()
        #expect(completedDuringMutation == .timedOut)
        #expect(store.read { $0.records["record"] } == Data([1]))
    }

    @Test("Concurrent record, list, token, and snapshot operations preserve state")
    func concurrentUpdatesAndSnapshots() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = SyncEngineStateStore(fileURL: url, initialState: State())
        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            for index in 0..<50 {
                let key = "\(worker)-\(index)"
                store.update {
                    $0.records[key] = Data(key.utf8)
                    $0.listReferences[key] = "list-\(worker)"
                }
                let snapshot = store.read { $0 }
                store.update {
                    $0.token = Data(key.utf8)
                    $0.seeded = true
                }
                #expect(snapshot.records[key] == Data(key.utf8))
                #expect(snapshot.records.count == snapshot.listReferences.count)
            }
        }
        store.flush()
        let saved = try JSONDecoder().decode(State.self, from: Data(contentsOf: url))
        #expect(saved.records.count == 400)
        #expect(saved.listReferences.count == 400)
        #expect(saved.seeded)
        #expect(saved.token != nil)
        let reopened = SyncEngineStateStore(fileURL: url, initialState: State())
        #expect(reopened.read { $0.records } == saved.records)
    }

    @Test("Previously returned snapshots remain immutable")
    func snapshotIsStable() {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = SyncEngineStateStore(fileURL: url, initialState: State())
        store.update { $0.records["old"] = Data([1]) }
        let before = store.read { $0 }
        store.update { $0.records["new"] = Data([2]) }
        store.flush()
        #expect(before.records.count == 1)
        #expect(before.records["new"] == nil)
        #expect(store.read { $0.records.count } == 2)
    }

    @Test("Invalid state files fall back without deleting unrelated files")
    func invalidState() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("invalid".utf8).write(to: url)
        let sibling = url.deletingLastPathComponent().appendingPathComponent("blob.bin")
        try Data([9]).write(to: sibling)
        let store = SyncEngineStateStore(fileURL: url, initialState: State())
        #expect(store.read { $0.records.isEmpty })
        store.update { $0.seeded = true }
        store.flush()
        #expect(try Data(contentsOf: sibling) == Data([9]))
        #expect(try JSONDecoder().decode(State.self, from: Data(contentsOf: url)).seeded)
    }
}
