import Foundation
import Observation
import CoreData

/// App-scoped observable that increments `tick` every time CloudKit
/// imports changes into the local SwiftData store. Views that need to
/// re-fetch on sync events observe `tick` via `@Bindable` / `.onChange`
/// instead of subscribing to `NSPersistentStoreRemoteChange` themselves.
///
/// **Why this exists:** SwiftUI's `.onReceive(NotificationCenter...)` is
/// unreliable for views hosted inside `NSHostingController` (e.g. the
/// Mac menu-bar popover). AppKit's notification center fires fine, but
/// SwiftUI's bridge to it doesn't always deliver to views that aren't
/// in a full `Scene`. Moving the subscription into an `@Observable`
/// object and letting SwiftUI observe its state via its native
/// observation tracking dodges that entire class of delivery bug.
///
/// **Primary trigger is explicit** — `CopiedSyncEngine.handleFetchedRecordZoneChanges`
/// calls `SyncTicker.shared.bump()` after applying imports. The
/// `NSPersistentStoreRemoteChange` observer is retained as a
/// belt-and-suspenders for genuine cross-process writes (Share
/// Extension → App Group store), but our main-process CKSyncEngine
/// saves never fire it reliably (NSPCKC is disabled — see
/// `CopiedSchema.makeContainer`), so the explicit bump is the
/// load-bearing path.
///
/// Mirror use on both platforms — Mac popover needs it because of the
/// NSHostingController scoping, iOS mirrors for consistency (harmless
/// overhead there since iOS's `Scene` graph already reacts correctly).
@Observable
@MainActor
public final class SyncTicker {
    public static let shared = SyncTicker()

    /// Monotonically-increasing counter. Watchers react to each bump by
    /// re-fetching / recomputing. The absolute value is meaningless —
    /// only *changed* matters.
    public private(set) var tick: Int = 0

    /// Explicit poke — lets user-initiated "Sync Now" flow through the
    /// same observation path as automatic CloudKit import ticks. Views
    /// observing `.tick` refresh immediately.
    public func bump() {
        tick &+= 1
    }

    private var observers: [NSObjectProtocol] = []

    private init() {
        // Keep the `NSPersistentStoreRemoteChange` observer for genuine
        // cross-process writes (e.g. the iOS Share Extension writing
        // into the App Group store). Our in-process CKSyncEngine saves
        // don't post this notification reliably with NSPCKC disabled —
        // `CopiedSyncEngine.handleFetchedRecordZoneChanges` bumps us
        // explicitly instead. The `NSPersistentCloudKitContainer.eventChangedNotification`
        // observer that used to live here was removed: NSPCKC is
        // disabled (see `CopiedSchema.makeContainer` → `cloudKitDatabase: .none`),
        // so the notification would never fire and its `.setup` event
        // used to cause a spurious post-launch tick.
        let change = NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.tick &+= 1 }
        }
        observers.append(change)
    }

    // SyncTicker is an app-lifetime singleton; deinit never runs in
    // practice. Explicit observer cleanup isn't needed — if it ever did
    // deinit, the process is about to exit anyway. Skipping cleanup
    // avoids the Swift 6 main-actor-isolation error on nonisolated deinit.
}
