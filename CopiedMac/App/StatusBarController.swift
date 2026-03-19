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

    /// Stored from SwiftUI's @Environment(\.openSettings) — the only reliable
    /// way to open Settings on macOS 14+. Captured by PopoverView on appear.
    var settingsAction: OpenSettingsAction?

    private override init() { super.init() }

    func setup<Content: View>(@ViewBuilder content: () -> Content) {
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
        pop.contentViewController = NSHostingController(rootView: content())

        self.statusItem = item
        self.popover = pop
        self.contextMenu = menu
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

    /// Called by click — button is already positioned, show immediately.
    private func showPopoverImmediate() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        configurePopoverWindowForFullScreen()
        installCloseMonitors()
        appState?.popoverIsVisible = true
    }

    /// Called by hotkey — needs delay for AppKit to lay out the status item window.
    private func showPopoverFromHotkey() {
        guard let button = statusItem.button else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [self] in
            guard !popover.isShown else { return }
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
    }

    // MARK: - Settings

    @objc func openSettings() {
        // Fire the SwiftUI action FIRST while the popover is still shown
        // and the app is still active — this ensures the scene graph is engaged.
        settingsAction?()

        // Then close the popover and make the app a regular Dock citizen
        popover.performClose(nil)
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
        }

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
