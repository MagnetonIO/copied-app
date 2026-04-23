import AppKit
import SwiftUI

@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate, NSMenuDelegate {
    static let shared = StatusBarController()

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var contextMenu: NSMenu!
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    weak var appState: AppState?


    /// Factory to create the popover content on demand (avoids idle CPU from always-live SwiftUI views)
    private var contentFactory: (() -> AnyView)?

    private override init() { super.init() }

    func setup<Content: View>(@ViewBuilder content: @escaping () -> Content) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = item.button {
            button.image = NSImage(systemSymbolName: "list.clipboard.fill", accessibilityDescription: "Copied")
            button.image?.size = NSSize(width: 16, height: 16)
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(statusBarClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Copied", action: #selector(quitApp), keyEquivalent: "q")
        for menuItem in menu.items { menuItem.target = self }

        let pop = NSPopover()
        pop.contentSize = NSSize(width: 400, height: 540)
        pop.behavior = .applicationDefined
        pop.animates = true
        pop.delegate = self

        self.statusItem = item
        self.popover = pop
        self.contextMenu = menu
        self.contentFactory = { AnyView(content()) }

        // Pre-warm the SwiftUI hierarchy so the first popover open doesn't pay the
        // cost of NSHostingController alloc + @Query fetch + List first-layout.
        let hosting = NSHostingController(rootView: AnyView(content()))
        _ = hosting.view  // force view loading
        popover.contentViewController = hosting
    }

    // MARK: - Status bar click

    @objc private func statusBarClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            showPopoverImmediate()
            return
        }

        if event.type == .rightMouseUp {
            statusItem.menu = contextMenu
            sender.performClick(nil)
        } else {
            togglePopoverInternal()
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        statusItem.menu = nil
    }

    // MARK: - Toggle (called by hotkey)

    @objc func togglePopover(_ sender: Any? = nil) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopoverFromHotkey()
        }
    }

    private func togglePopoverInternal() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopoverImmediate()
        }
    }

    /// Attaches the pre-warmed SwiftUI view to the popover. Pre-warming
    /// keeps popover open snappy (~instant) at the cost of the view tree
    /// persisting across opens. The query-generation staleness we saw
    /// earlier was actually an APS/CloudKit-environment mismatch (silent
    /// pushes landing on the wrong APNs channel), not a view-layer issue.
    /// With aps-environment=production matching the CloudKit Production
    /// database, imports now arrive and the pre-warmed popover reflects
    /// them via SyncTicker → recomputeFiltered.
    private func attachContentIfNeeded() {
        if popover.contentViewController == nil, let factory = contentFactory {
            popover.contentViewController = NSHostingController(rootView: factory())
        }
    }

    /// Called by click — button is already positioned, show immediately.
    private func showPopoverImmediate() {
        guard let button = statusItem.button else { return }
        attachContentIfNeeded()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        configurePopoverWindowForFullScreen()
        installCloseMonitors()
        appState?.popoverIsVisible = true
    }

    /// Called by hotkey — was formerly throttled by 150 ms `asyncAfter` to wait for
    /// AppKit to lay out the status item window; dropped to next runloop since the
    /// status button is already laid out in a running app and 150 ms is perceptible.
    private func showPopoverFromHotkey() {
        guard let button = statusItem.button else { return }
        DispatchQueue.main.async { [self] in
            guard !popover.isShown else { return }
            attachContentIfNeeded()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            configurePopoverWindowForFullScreen()
            installCloseMonitors()
            popover.contentViewController?.view.window?.makeKeyAndOrderFront(nil)
            appState?.popoverIsVisible = true
        }
    }

    /// Patches the popover's window so it can appear over fullscreen Spaces.
    /// NSPopover creates its window lazily at show-time, so this must be called
    /// immediately after every `popover.show(...)`.
    private func configurePopoverWindowForFullScreen() {
        guard let popoverWindow = popover.contentViewController?.view.window else { return }
        popoverWindow.collectionBehavior.insert(.fullScreenAuxiliary)
        popoverWindow.collectionBehavior.insert(.canJoinAllSpaces)
    }

    // MARK: - Close monitors (replaces .transient behavior)

    private func installCloseMonitors() {
        removeCloseMonitors()

        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.popover.performClose(nil)
        }

        localClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self else { return event }

            // Escape key closes popover
            if event.type == .keyDown && event.keyCode == 53 {
                self.popover.performClose(nil)
                return nil
            }

            // Pass through clicks inside the popover window
            if let popoverWindow = self.popover.contentViewController?.view.window,
               event.window == popoverWindow {
                return event
            }

            // Pass through clicks on the status bar button (toggle behavior)
            if event.window == self.statusItem.button?.window {
                return event
            }

            // Click elsewhere in our app — close popover
            self.popover.performClose(nil)
            return event
        }
    }

    private func removeCloseMonitors() {
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }
        if let monitor = localClickMonitor {
            NSEvent.removeMonitor(monitor)
            localClickMonitor = nil
        }
    }

    // MARK: - NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        removeCloseMonitors()
        appState?.popoverIsVisible = false
        // Keep contentViewController alive across opens so subsequent shows are instant.
        // @Query stays subscribed but is cheap when data doesn't change; the SwiftUI
        // view goes through .onDisappear / .onAppear via `popoverIsVisible` which is
        // what we use for work gating.
    }

    // MARK: - Settings

    @objc func openSettings() {
        popover.performClose(nil)
        statusItem.menu = nil

        // Deterministic first-click open — SettingsWindowController holds a real
        // NSWindow reference and calls makeKeyAndOrderFront directly. No responder
        // chain walk, no SwiftUI scene lazy init, works from a cold launch.
        SettingsWindowController.shared.show()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsWindowClosed(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
    }

    @objc private func settingsWindowClosed(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        let title = window.title.lowercased()
        guard title.contains("settings") || title.contains("preferences") else { return }

        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: nil)

        if !UserDefaults.standard.bool(forKey: "showInDock") {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    func closePopover() { popover.performClose(nil) }

    var isShown: Bool { popover.isShown }
}
