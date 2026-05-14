import SwiftUI
import SwiftData
import CopiedKit
import OSLog

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
    /// Controls MenuBarExtra popover visibility. `GlobalHotkeyManager`
    /// toggles this binding so ⌃⇧C opens/closes the popover.
    @State private var menuBarExtraIsPresented: Bool = false

    var body: some Scene {
        Window("Copied", id: "main") {
            MainWindowView()
                .environment(appDelegate.clipboardService)
                .environment(appDelegate.pasteQueue)
                .environment(appDelegate.appState)
                .environment(appDelegate.syncMonitor)
                .environment(SyncTicker.shared)
                .onOpenURL { url in
                    handleIncomingURL(url)
                }
        }
        .modelContainer(SharedData.container)
        .defaultSize(width: 900, height: 600)
        .defaultPosition(.center)
        .handlesExternalEvents(matching: ["copied"])

        // MenuBarExtra hosts the popover as a full SwiftUI Scene. The
        // scene body (including every `@Query` inside `PopoverView`) is
        // alive for the app's lifetime, whether the popover is shown or
        // not — which is what makes CKSyncEngine imports visibly
        // update the popover in real time without requiring the user
        // to open the main window. Pre-2025 this path was an
        // NSPopover + NSHostingController built by `StatusBarController`;
        // migrating to MenuBarExtra eliminated the @Query-not-observing
        // dead time that manifested as "sync only works when I click
        // the main window."
        MenuBarExtra(isInserted: .constant(true)) {
            PopoverView()
                .environment(appDelegate.clipboardService)
                .environment(appDelegate.pasteQueue)
                .environment(appDelegate.appState)
                .environment(appDelegate.syncMonitor)
                .environment(SyncTicker.shared)
                .frame(width: 400, height: 540)
        } label: {
            Image(systemName: "list.clipboard")
        }
        .menuBarExtraStyle(.window)
        .modelContainer(SharedData.container)

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
    private let syncProfileLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Copied",
        category: "SyncProfile"
    )
    // Register defaults early so they're available when stored properties initialize
    private static let _registerDefaults: Void = {
        UserDefaults.standard.register(defaults: [
            "captureImages": true,
            "captureRichText": true,
            "pasteAndClose": true,
            "cloudSyncEnabled": true,
            "popoverItemCount": 100,
            "maxHistorySize": 500,        // was 5000 — tighter default
            "stripURLTrackingParams": true,
            "retentionDays": 30,          // was -1 (unlimited) — 30 day default
            "trashRetentionDays": 30,
            "iCloudSyncPurchased": false,
            "showWindowOnLaunch": false
        ])
    }()

    let clipboardService: ClipboardService = {
        _ = AppDelegate._registerDefaults
        return ClipboardService()
    }()

    /// App-lifetime observer for `NSPersistentStoreRemoteChange`. See
    /// `applicationDidFinishLaunching` for the wiring.
    private var remoteChangeObserver: NSObjectProtocol?
    /// Background sync triggers. CKSyncEngine's auto-sync relies on
    /// silent push, which is unreliable on dev-signed Mac binaries
    /// (Apple forum FB8968738). These explicit triggers compensate.
    /// Unlike the old NSPCKC `mirrorPoke` path, these call
    /// `CopiedSyncEngine.syncNow()` which is fully async — no
    /// main-thread stall.
    private var didBecomeActiveObserver: NSObjectProtocol?
    private var didBecomeKeyWindowObserver: NSObjectProtocol?
    private var didWakeObserver: NSObjectProtocol?
    /// Observer for the darwin notification posted by `GlobalHotkeyManager`
    /// when ⌃⇧C fires. The handler programmatically clicks the
    /// MenuBarExtra status-bar button, which opens the popover the
    /// same code path a real click takes.
    private var hotkeyToggleObserver: NSObjectProtocol?
    /// NSEvent local monitor for right-click on the menu bar icon.
    /// MenuBarExtra owns the status item and shows the popover on
    /// left-click; we monitor right-click on its host window and
    /// surface our own context menu (Settings / Open Main Window /
    /// Quit) — the standard Mac convention for menu-bar utilities.
    private var menuBarRightClickMonitor: Any?
    private var syncBackstopTimer: Timer?
    private let syncBackstopFastInterval: TimeInterval = 5
    private let syncBackstopIdleInterval: TimeInterval = 30
    private let syncBackstopFastGrace: TimeInterval = 90
    private var lastInteractiveSyncSignalAt: Date = Date()
    private var lastBackstopManualPullAt: Date = .distantPast
    /// Listens for OS memory-pressure events. On `.warning` or `.critical`,
    /// drops in-memory caches (thumbnails, app icons, SwiftData row cache).
    /// Without this, the menu-bar app's RSS grows unbounded as the user
    /// browses image-heavy histories — `mainContext` materializes every
    /// `imageData`/`richTextData`/`htmlData` blob it touches and never
    /// releases them.
    private var memoryPressureSource: DispatchSourceMemoryPressure?
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

        // Activation policy stays `.regular` (Info.plist `LSUIElement=false`).
        // Dock icon is always present; the main window is hidden on launch
        // via the `showWindowOnLaunch` default below.

        let ctx = ModelContext(SharedData.container)
        clipboardService.configure(modelContext: ctx)
        clipboardService.start()

        // One-shot v1.3.0 cleanup: tighten retention defaults across
        // the board (500 clippings, 30-day age retention, 30-day trash)
        // and sweep out "Empty Clipping" rows left behind by earlier
        // capture-path bugs. Gated on a single UserDefaults flag so it
        // runs exactly once per device. Safe to leave in the code path
        // forever — once the flag is set, subsequent launches skip.
        if !UserDefaults.standard.bool(forKey: "didApplyV130CleanupV3") {
            UserDefaults.standard.set(500, forKey: "maxHistorySize")
            UserDefaults.standard.set(30, forKey: "retentionDays")
            UserDefaults.standard.set(30, forKey: "trashRetentionDays")
            clipboardService.purgeEmptyClippings(in: ctx)
            UserDefaults.standard.set(true, forKey: "didApplyV130CleanupV3")
        }

        clipboardService.trimByAge()
        clipboardService.purgeOldTrash()
        // Prune QuickLook temp files older than 24 h (default viewer
        // exports for snippets and images). Previously these landed in
        // /tmp and were never cleaned; now they live under
        // ~/Library/Caches/Copied/quicklook/ and this pass keeps the
        // directory bounded.
        ClipboardService.cleanupQuickLookCache()

        syncMonitor.start()

        // CKSyncEngine (iOS 17 / macOS 14+) — replaces NSPCKC automatic
        // mirroring. Starts only when the user's cloudSync gate is on.
        // Engine manages its own APNs subscriptions; no extra
        // `registerForRemoteNotifications` call needed for it.
        // Wire the engine's status updates through to the existing
        // `SyncMonitor` so the popover pill and settings view bind
        // unchanged — engine drives the label, monitor is the façade.
        CopiedSyncEngine.shared.syncMonitor = syncMonitor
        if SharedData.initialCloudSyncEnabled {
            CopiedSyncEngine.shared.start(modelContainer: SharedData.container)
        }

        // Background sync triggers — compensate for flaky silent-push
        // delivery on dev-signed Mac binaries. Keep the reliable
        // fallback at the app layer rather than hanging correctness off
        // which SwiftUI scene happens to be focused.
        //
        // 1. App activation (Cmd-Tab back, Dock click): immediate catch-up
        didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                self.noteInteractiveSyncSignal()
                self.syncProfileLogger.log("trigger didBecomeActive")
            }
            Task.detached { await CopiedSyncEngine.shared.fetchChanges(source: "mac.didBecomeActive") }
        }
        // 1b. Window-key transitions are the strongest concrete signal we
        // have for MenuBarExtra visibility. `scenePhase` has proven too
        // weak for the popover, but the hosting NSWindow becoming key is
        // reliable and lines up with the "user opened a surface, sync it
        // now" behavior we want.
        didBecomeKeyWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let window = note.object as? NSWindow else { return }
            Task { @MainActor in
                let className = String(describing: type(of: window))
                let title = window.title
                let source: String = (title == "Copied")
                    ? "mac.mainWindow.didBecomeKey"
                    : "mac.window.didBecomeKey"

                self.noteInteractiveSyncSignal()
                self.syncProfileLogger.log(
                    "trigger windowDidBecomeKey source=\(source, privacy: .public) class=\(className, privacy: .public) title=\(title, privacy: .public)"
                )
                Task.detached { await CopiedSyncEngine.shared.fetchChanges(source: source) }
            }
        }
        // 2. Wake from sleep: network just came back, force a pull
        didWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                self.noteInteractiveSyncSignal()
                self.syncProfileLogger.log("trigger didWake")
            }
            Task.detached { await CopiedSyncEngine.shared.fetchChanges(source: "mac.didWake") }
        }
        // 3. App-lifetime backstop. Poll fast around visible user
        // interaction, then fall back to a slower idle cadence. The
        // timer still runs for the whole app lifetime so correctness
        // does not depend on a particular SwiftUI scene staying mounted.
        syncBackstopTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            Task { @MainActor in self.runSyncBackstopIfDue() }
        }
        if let syncBackstopTimer {
            RunLoop.main.add(syncBackstopTimer, forMode: .common)
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

        // Memory-pressure handler. The dispatch source fires on the main
        // queue when the OS is under memory pressure; we drop the bounded
        // in-memory caches and roll back the shared mainContext so its row
        // cache (including any materialized externalStorage blobs) is
        // released. Persisted state is unaffected — every mutation already
        // saves immediately, so there are no pending changes to lose.
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.purgeInMemoryCaches(reason: "memoryPressure")
        }
        source.resume()
        memoryPressureSource = source

        #if MAS_STOREFRONT
        // Start the Transaction.updates listener early so Ask-to-Buy approvals,
        // refunds, and revocations that arrive after launch are caught. Only in
        // App Store-distributed builds (MAS_STOREFRONT). Direct-download variants
        // (LICENSE_STRIPE) unlock via a signed license JWT from Stripe Checkout,
        // not StoreKit, so no listener is needed there.
        _ = PurchaseManager.shared
        #endif

        // Menubar popover is now served by `MenuBarExtra` in
        // `CopiedMacApp.body`. `StatusBarController` is deleted.

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

        // Register global hotkey (⌃⇧C). Posts a darwin notification
        // that `CopiedMacApp` (which owns the MenuBarExtra's
        // `isInserted` binding) observes — toggles popover visibility.
        GlobalHotkeyManager.shared.register {
            NotificationCenter.default.post(
                name: Notification.Name("com.magneton.copied.toggleMenuBarPopover"),
                object: nil
            )
        }

        // Observe the hotkey notification and route it to the
        // MenuBarExtra's underlying NSStatusBarButton. MenuBarExtra
        // does not expose a programmatic "open popover" API, so we
        // find the status item button in the app's window list and
        // performClick on it — that drives the same code path as a
        // real user click on the menu bar icon.
        hotkeyToggleObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("com.magneton.copied.toggleMenuBarPopover"),
            object: nil,
            queue: .main
        ) { _ in
            // Notification observer closure is Sendable, but toggleMenuBarPopover()
            // is @MainActor. Hop explicitly to silence Swift 6 strict-concurrency
            // warning (queue: .main already guarantees main thread, but the type
            // checker doesn't know that).
            Task { @MainActor in self.toggleMenuBarPopover() }
        }

        // Right-click on the menu bar icon → context menu.
        // MenuBarExtra hosts the status item button in a window
        // whose class name contains "StatusBar". A local NSEvent
        // monitor sees right-click events targeting that window and
        // shows our NSMenu instead of letting the click propagate
        // (which would either no-op or open the regular popover).
        menuBarRightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard let self else { return event }
            guard let button = self.findMenuBarExtraButton(),
                  let buttonWindow = button.window,
                  event.window === buttonWindow else {
                return event
            }
            DispatchQueue.main.async {
                self.showMenuBarRightClickMenu(from: button)
            }
            return nil
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

    private func noteInteractiveSyncSignal() {
        lastInteractiveSyncSignalAt = Date()
    }

    private func runSyncBackstopIfDue() {
        let now = Date()
        let recentlyInteractive = now.timeIntervalSince(lastInteractiveSyncSignalAt) < syncBackstopFastGrace
        let fastCadence = NSApp.isActive || appState.popoverIsVisible || recentlyInteractive
        let interval = fastCadence ? syncBackstopFastInterval : syncBackstopIdleInterval

        guard now.timeIntervalSince(lastBackstopManualPullAt) >= interval else { return }
        lastBackstopManualPullAt = now

        let cadence = fastCadence ? "fast" : "idle"
        syncProfileLogger.log("trigger appTimer cadence=\(cadence, privacy: .public)")
        // Use manualInboundFetch — `engine.fetchChanges()` is a no-op
        // on this path because macOS withholds CloudKit silent pushes
        // from the background menu-bar app. The manual fetch issues a
        // real `CKFetchRecordZoneChangesOperation` against our own
        // change token. Cooldown gate lives inside the engine.
        Task.detached { await CopiedSyncEngine.shared.manualInboundFetch(source: "mac.appTimer.\(cadence)") }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // Keep running as menu bar app even when all windows close
    }

    // MARK: - CloudKit silent push → CKSyncEngine fetch

    /// CloudKit sends a silent push whenever the private zone (Copied)
    /// has new changes. `NSApp.registerForRemoteNotifications()` above
    /// asks the OS to deliver those pushes to this app; this delegate
    /// method is where we forward them to CKSyncEngine so the engine
    /// fetches the new records. Without this, pushes arrive at the OS
    /// and never reach the engine — which is exactly why sync only
    /// appeared to work when the user refocused a window (that path
    /// fires `didBecomeActive` → `fetchChanges`).
    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        syncProfileLogger.log("trigger remoteNotification")
        Task.detached { await CopiedSyncEngine.shared.fetchChanges(source: "mac.remoteNotification") }
    }

    /// APNs delivered a device token — log only. CKSyncEngine manages
    /// its own CKDatabaseSubscription, so we don't forward this token;
    /// presence just confirms push registration succeeded.
    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        NSLog("[CopiedMacApp] registered for remote notifications, token=\(deviceToken.count) bytes")
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NSLog("[CopiedMacApp] remote notification registration failed: \(error.localizedDescription)")
    }

    // MARK: - Hotkey → MenuBarExtra popover

    /// Programmatically open / close the MenuBarExtra popover by
    /// finding the underlying `NSStatusBarButton` in the app's
    /// window list and calling `performClick(nil)`. This is the
    /// only way to drive MenuBarExtra from a global hotkey —
    /// SwiftUI does not expose a presentation binding for the
    /// popover content. Walking `NSApp.windows` is stable across
    /// macOS 14+ but uses a class-name match (`NSStatusBarWindow`)
    /// to locate the status item's host window.
    @MainActor
    private func toggleMenuBarPopover() {
        guard let button = findMenuBarExtraButton() else {
            NSLog("[CopiedMacApp] hotkey: status bar button not found; popover will not toggle")
            return
        }
        if NSApp.isActive {
            // Already active — click goes straight through.
            button.performClick(nil)
        } else {
            // NSApp.activate is async; if we performClick synchronously,
            // the click reaches the button before the app/menu-bar
            // context is active, which only activates the app and
            // requires a second ⌃⇧C to actually open the popover.
            // Defer the click one runloop tick so activation lands first.
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.async {
                button.performClick(nil)
            }
        }
    }

    @MainActor
    private func findMenuBarExtraButton() -> NSStatusBarButton? {
        for window in NSApp.windows {
            let className = String(describing: type(of: window))
            // MenuBarExtra hosts its status item inside a window whose
            // class contains "StatusBar" (private). Filter to those
            // before walking subviews to keep the search cheap.
            guard className.contains("StatusBar") else { continue }
            if let button = recursiveFindStatusBarButton(in: window.contentView) {
                return button
            }
        }
        return nil
    }

    @MainActor
    private func recursiveFindStatusBarButton(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for sub in view.subviews {
            if let found = recursiveFindStatusBarButton(in: sub) {
                return found
            }
        }
        return nil
    }

    // MARK: - Menu bar right-click menu

    @MainActor
    private func showMenuBarRightClickMenu(from button: NSStatusBarButton) {
        let menu = NSMenu()
        let openMain = NSMenuItem(
            title: "Open Main Window",
            action: #selector(rightClickMenuOpenMainWindow),
            keyEquivalent: ""
        )
        openMain.target = self
        menu.addItem(openMain)

        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(rightClickMenuOpenSettings),
            keyEquivalent: ""
        )
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit Copied",
            action: #selector(rightClickMenuQuit),
            keyEquivalent: ""
        )
        quit.target = self
        menu.addItem(quit)

        // Pop up below the status bar button.
        let location = NSPoint(x: 0, y: button.bounds.height + 4)
        menu.popUp(positioning: nil, at: location, in: button)
    }

    @objc private func rightClickMenuOpenMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        // If the window already exists, just bring it forward.
        for window in NSApp.windows where window.title == "Copied" {
            window.makeKeyAndOrderFront(nil)
            return
        }
        // Otherwise route through the existing copied:// URL handler
        // — that scene's .onOpenURL calls openWindow(id: "main").
        if let url = URL(string: "copied://") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func rightClickMenuOpenSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func rightClickMenuQuit() {
        NSApp.terminate(nil)
    }

    /// Drops every in-memory cache that grows with usage. Called from the
    /// memory-pressure dispatch source, popover dismiss
    /// (`NSWindow.didResignKey`), and main window close. Persistent SwiftData
    /// state is unaffected — `mainContext.rollback()` only releases the row
    /// cache, since every mutation has already been saved.
    func purgeInMemoryCaches(reason: String) {
        ThumbnailCache.shared.purge()
        AppIconCache.shared.purge()
        SharedData.container.mainContext.rollback()
        syncProfileLogger.log("purgeInMemoryCaches reason=\(reason, privacy: .public)")
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
