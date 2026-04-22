import AppKit
import SwiftUI

/// AppKit-controlled Settings window. Replaces SwiftUI's `Settings { }` scene
/// because that scene's prefs-panel NSWindow kept snapping back to its original
/// origin during fast drags (a SwiftUI layout/feedback-loop quirk), and its
/// `showSettingsWindow:` responder only registered after the scene had been
/// realized on-screen once — so the first right-click → Settings silently failed
/// on a cold launch.
///
/// This wrapper:
///   • Hosts the same `SettingsView` via `NSHostingController` — the SwiftUI
///     TabView renders natively inside an NSWindow.
///   • Creates a standard `.titled` NSWindow at launch, so there's no SwiftUI
///     scene layout feedback loop fighting drag-to-move.
///   • Exposes a deterministic `show()` that works from the very first user
///     click — no responder-chain walk, no selector send.
///   • Autosaves window position via `setFrameAutosaveName`.
@MainActor
final class SettingsWindowController: NSObject {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private var contentFactory: (() -> AnyView)?

    private override init() { super.init() }

    /// Call once from `applicationDidFinishLaunching` with a factory that returns
    /// the fully-wired SettingsView (env + modelContainer already applied).
    /// The window is materialized immediately so SwiftUI realizes the hosting
    /// controller's view and `.onAppear` / @AppStorage reads fire at launch.
    func setup(content: @escaping () -> AnyView) {
        contentFactory = content
        ensureWindow()
    }

    /// Bring the Settings window to front. Activates the app first so the
    /// window actually comes forward even for `.accessory`-policy processes.
    func show() {
        ensureWindow()
        guard let window else { return }

        if NSApp.activationPolicy() == .accessory {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func ensureWindow() {
        guard window == nil, let factory = contentFactory else { return }

        let hosting = NSHostingController(rootView: factory())
        let w = NSWindow(contentViewController: hosting)
        w.title = "Copied Settings"
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.isReleasedWhenClosed = false
        w.setContentSize(NSSize(width: 560, height: 500))
        w.center()
        w.setFrameAutosaveName("CopiedSettingsWindow")

        self.window = w

        // Force the hosting controller to load its view immediately so SwiftUI
        // realizes SettingsView (and any .onAppear work) at app launch.
        _ = hosting.view
    }
}
