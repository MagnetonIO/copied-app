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
        // Subscribe to BOTH known SwiftData-CloudKit change signals:
        //   1. `NSPersistentStoreRemoteChange` — posted on local saves and
        //      coordinator-level store changes. Fires for some CloudKit
        //      imports but unreliably on macOS 15 (confirmed empirically:
        //      main window and popover alike only refresh on view-mount,
        //      not on this notification).
        //   2. `NSPersistentCloudKitContainer.eventChangedNotification` —
        //      the authoritative CloudKit integration event bus. Fires on
        //      every .import / .export / .setup start AND end. This is
        //      what actually carries news of iOS-side adds/deletes into
        //      Mac's process.
        // Bump on either so views observing `.tick` refresh in real time.
        let change = NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.tick &+= 1 }
        }
        observers.append(change)

        let ckEvent = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil,
            queue: nil
        ) { [weak self] note in
            let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                as? NSPersistentCloudKitContainer.Event
            guard let event, event.endDate != nil, event.type == .import else { return }
            Task { @MainActor in self?.tick &+= 1 }
        }
        observers.append(ckEvent)
    }

    // SyncTicker is an app-lifetime singleton; deinit never runs in
    // practice. Explicit observer cleanup isn't needed — if it ever did
    // deinit, the process is about to exit anyway. Skipping cleanup
    // avoids the Swift 6 main-actor-isolation error on nonisolated deinit.
}
