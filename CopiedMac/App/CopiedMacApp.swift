import SwiftUI
import SwiftData
import CopiedKit

/// Shared container — single instance used by both popover and window.
enum SharedData {
    @MainActor
    static let initialCloudSyncEnabled: Bool = computeCloudSyncEnabled()

    @MainActor
    private static func computeCloudSyncEnabled() -> Bool {
        let userToggle = UserDefaults.standard.object(forKey: "cloudSyncEnabled") as? Bool ?? true
        #if MAS_BUILD
        let purchased = UserDefaults.standard.bool(forKey: "iCloudSyncPurchased")
        return userToggle && purchased
        #else
        return userToggle
        #endif
    }

    /// True when cloudSync gate state has drifted from what the container
    /// was built with — meaning a mid-session unlock happened and writes
    /// are still going to a local-only store. SettingsView surfaces this
    /// as a banner with a Quit button so the user can restart cleanly.
    @MainActor
    static var requiresRelaunchForSync: Bool {
        computeCloudSyncEnabled() != initialCloudSyncEnabled
    }

    @MainActor
    static let container: ModelContainer = {
        let cloudSyncEnabled = initialCloudSyncEnabled
        do {
            return try CopiedSchema.makeContainer(cloudSync: cloudSyncEnabled)
        } catch {
            NSLog("CloudKit container failed: \(error). Falling back to local-only.")
            do {
                return try CopiedSchema.makeContainer(cloudSync: false)
            } catch {
                fatalError("Failed to create ModelContainer: \(error)")
            }
        }
    }()
}

@main
struct CopiedMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("Copied", id: "main") {
            MainWindowView()
                .environment(appDelegate.clipboardService)
                .environment(appDelegate.pasteQueue)
                .environment(appDelegate.appState)
                .environment(appDelegate.syncMonitor)
                .onOpenURL { url in
                    handleIncomingURL(url)
                }
                .onReceive(NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange)) { _ in
                    // CloudKit just imported changes from iOS. Force the
                    // main context to process them so @Query observers
                    // re-evaluate their predicates — without this, a
                    // clipping that iOS marked `deleteDate = now` still
                    // appears in the Mac main list until the app relaunches.
                    SharedData.container.mainContext.processPendingChanges()
                }
        }
        .modelContainer(SharedData.container)
        .defaultSize(width: 900, height: 600)
        .defaultPosition(.center)
        .handlesExternalEvents(matching: ["copied"])

        // Settings is served by SettingsWindowController (AppKit NSWindow), not by
        // SwiftUI's `Settings { }` scene — the scene's prefs-panel window snaps back
        // during fast drags and its responder registers lazily, breaking first-click
        // opens on a cold launch.
    }

    /// Routes `copied://` URLs into app state. Currently supports:
    /// - `copied://search?q=<text>` — open main window, seed the search query.
    @MainActor
    private func handleIncomingURL(_ url: URL) {
        guard url.scheme == "copied" else { return }
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "main")

        if url.host(percentEncoded: false) == "search" {
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let query = components?.queryItems?.first(where: { $0.name == "q" })?.value ?? ""
            appDelegate.appState.searchText = query
            appDelegate.appState.sidebarSelection = .all
        }

        #if LICENSE_STRIPE
        if url.host(percentEncoded: false) == "unlock" {
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let key = components?.queryItems?.first(where: { $0.name == "key" })?.value ?? ""
            guard !key.isEmpty else { return }
            do {
                _ = try LicenseStore.storeAndVerify(license: key)
                // Flag is now set; kick off the same restart flow the MAS purchase uses
                // so the ModelContainer rebuilds with cloudSync enabled.
                AppRestarter.restartAfterPurchase()
            } catch {
                NSLog("License unlock failed: \(error)")
            }
        }
        #endif
    }
}

// MARK: - App Delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Register defaults early so they're available when stored properties initialize
    private static let _registerDefaults: Void = {
        UserDefaults.standard.register(defaults: [
            "captureImages": true,
            "captureRichText": true,
            "allowDuplicates": false,
            "pasteAndClose": true,
            "cloudSyncEnabled": true,
            "popoverItemCount": 100,
            "maxHistorySize": 5000,
            "stripURLTrackingParams": true,
            "retentionDays": -1,
            "trashRetentionDays": 30,
            "iCloudSyncPurchased": false
        ])
    }()

    let clipboardService: ClipboardService = {
        _ = AppDelegate._registerDefaults
        return ClipboardService()
    }()

    /// App-lifetime observer for `NSPersistentStoreRemoteChange`. See
    /// `applicationDidFinishLaunching` for the wiring.
    private var remoteChangeObserver: NSObjectProtocol?
    let pasteQueue = PasteQueueService()
    let appState = AppState()
    let syncMonitor = SyncMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Force-init the SyncTicker singleton before any view/model work so
        // its `.import` / remote-change observers are wired from t=0. Without
        // this, imports that fire during launch (or before the first popover
        // open instantiates `SyncTicker.shared` lazily) are missed and the
        // UI stays stale.
        _ = SyncTicker.shared

        // One-time fix: the old init code had a bug that set captureImages=false
        // in UserDefaults even though the user never toggled it. Reset to true
        // for users affected by this bug (key "didFixCaptureImagesDefault").
        if !UserDefaults.standard.bool(forKey: "didFixCaptureImagesDefault") {
            UserDefaults.standard.set(true, forKey: "captureImages")
            UserDefaults.standard.set(true, forKey: "captureRichText")
            UserDefaults.standard.set(true, forKey: "didFixCaptureImagesDefault")
            clipboardService.captureImages = true
            clipboardService.captureRichText = true
        }

        #if LICENSE_STRIPE
        // Reconcile Keychain → UserDefaults so the purchased flag survives reinstall.
        // Keychain is the source of truth; UserDefaults is the hot-path mirror.
        _ = LicenseStore.refreshFromKeychain()
        #endif

        // Hide from Dock by default (menu bar only)
        let showInDock = UserDefaults.standard.bool(forKey: "showInDock")
        if !showInDock {
            NSApp.setActivationPolicy(.accessory)
        }

        let ctx = ModelContext(SharedData.container)
        clipboardService.configure(modelContext: ctx)
        clipboardService.start()
        clipboardService.trimByAge()
        clipboardService.purgeOldTrash()

        syncMonitor.start()

        // CKSyncEngine (iOS 17 / macOS 14+) — replaces NSPCKC automatic
        // mirroring. Starts only when the user's cloudSync gate is on.
        // Engine manages its own APNs subscriptions; no extra
        // `registerForRemoteNotifications` call needed for it.
        if SharedData.initialCloudSyncEnabled {
            CopiedSyncEngine.shared.start(modelContainer: SharedData.container)
        }

        // CloudKit continuous sync: register for remote notifications so
        // NSPersistentCloudKitContainer can wake the Mac when iOS modifies
        // a record. The APNs token goes straight to the CloudKit framework.
        // Still needed during the dual-path transition (Phases 2–6 run the
        // legacy NSPCKC mirror alongside CKSyncEngine). Phase 7 removes.
        NSApp.registerForRemoteNotifications()

        // R-1: App-lifetime remote-change observer. MainWindowView and
        // PopoverView each have their own observers, but those only fire
        // once their view is mounted. This one fires regardless of which
        // UI (if any) is showing — so the main-actor context always
        // merges imported CloudKit changes as they arrive. Token is held
        // in the AppDelegate so the observer outlives window lifecycles.
        remoteChangeObserver = NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                SharedData.container.mainContext.processPendingChanges()
            }
        }

        #if MAS_STOREFRONT
        // Start the Transaction.updates listener early so Ask-to-Buy approvals,
        // refunds, and revocations that arrive after launch are caught. Only in
        // App Store-distributed builds (MAS_STOREFRONT). Direct-download variants
        // (LICENSE_STRIPE) unlock via a signed license JWT from Stripe Checkout,
        // not StoreKit, so no listener is needed there.
        _ = PurchaseManager.shared
        #endif

        // Set up status bar popover
        StatusBarController.shared.appState = appState
        StatusBarController.shared.setup {
            PopoverView()
                .environment(self.clipboardService)
                .environment(self.pasteQueue)
                .environment(self.appState)
                .environment(self.syncMonitor)
                .modelContainer(SharedData.container)
        }

        // Set up the Settings window (AppKit NSWindow hosting the SwiftUI SettingsView).
        // Materialized immediately so opening it on first click is instant.
        SettingsWindowController.shared.setup {
            AnyView(
                SettingsView()
                    .environment(self.clipboardService)
                    .environment(self.syncMonitor)
                    .modelContainer(SharedData.container)
            )
        }

        // Register global hotkey (⌃⇧C)
        GlobalHotkeyManager.shared.register {
            StatusBarController.shared.togglePopover()
        }

        // Prompt for accessibility
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            PermissionManager.ensureAccessibility()
        }

        // Close main window unless configured to show
        let showOnLaunch = UserDefaults.standard.bool(forKey: "showWindowOnLaunch")
        if !showOnLaunch {
            DispatchQueue.main.async {
                for window in NSApp.windows where window.title == "Copied" {
                    window.close()
                }
            }
        }

        #if MAS_BUILD
        // If we were relaunched by AppRestarter after a successful purchase, pop the
        // Settings window so the user lands on the Sync tab (pendingTab=3 was written
        // pre-relaunch) and sees the freshly-unlocked state without having to hunt for it.
        if UserDefaults.standard.bool(forKey: AppRestarter.restartedFromPurchaseKey) {
            UserDefaults.standard.removeObject(forKey: AppRestarter.restartedFromPurchaseKey)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                SettingsWindowController.shared.show()
            }
        }
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // Keep running as menu bar app even when all windows close
    }
}

@Observable
@MainActor
final class AppState {
    var selectedClipping: Clipping?
    var searchText: String = ""
    var filterKind: ContentKind?
    /// Popover list filter — when non-nil, the popover only shows
    /// clippings assigned to this `ClipList.listID`. The main window
    /// uses `sidebarSelection` for the same purpose; keeping them
    /// separate lets a user filter the popover without disturbing
    /// sidebar state.
    var popoverListFilterID: String?
    var popoverIsVisible: Bool = false
    var sidebarSelection: SidebarItem = .all
    var excludedBundleIDs: Set<String> = {
        let saved = UserDefaults.standard.stringArray(forKey: "excludedBundleIDs") ?? []
        return Set(saved)
    }()

    func saveExcludedApps() {
        UserDefaults.standard.set(Array(excludedBundleIDs), forKey: "excludedBundleIDs")
    }
}

enum SidebarItem: Hashable {
    case all
    case favorites
    case trash
    case list(ClipList)
}
