import Foundation

/// Confines metadata reads, mutations, and encoding to one queue. Closures must
/// not re-enter this store. State must use value semantics for safe snapshots.
final class SyncEngineStateStore<State: Codable & Sendable>: @unchecked Sendable {
    private var state: State
    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.magneton.copied.syncengine.state")

    init(fileURL: URL, initialState: State) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(State.self, from: data) {
            state = decoded
        } else {
            state = initialState
        }
    }

    func read<Result>(_ body: (State) -> Result) -> Result {
        queue.sync { body(state) }
    }

    @discardableResult
    func update<Result>(_ body: (inout State) -> Result) -> Result {
        queue.sync {
            let result = body(&state)
            // Enqueue while still owning the queue: no unsynchronized COW
            // snapshot, and an older write cannot overtake a newer mutation.
            queue.async { self.writeState() }
            return result
        }
    }

    /// Drains writes before a caller reads the file or tears down its owner.
    func flush() {
        queue.sync {}
    }

    private func writeState() {
        dispatchPrecondition(condition: .onQueue(queue))
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(state)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("[CopiedSyncEngine] persist failed: \(error.localizedDescription)")
        }
    }
}
