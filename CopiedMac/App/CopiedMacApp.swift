import SwiftUI
import SwiftData
import CopiedKit

/// Shared container — single instance used by both popover and window.
enum SharedData {
    @MainActor
    static let container: ModelContainer = {
        let cloudSyncEnabled = UserDefaults.standard.object(forKey: "cloudSyncEnabled") as? Bool ?? true
        // Try with CloudKit first, fall back to local-only if schema migration fails
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

    var body: some Scene {
        Window("Copied", id: "main") {
            MainWindowView()
                .environment(appDelegate.clipboardService)
                .environment(appDelegate.pasteQueue)
                .environment(appDelegate.appState)
                .environment(appDelegate.syncMonitor)
        }
        .modelContainer(SharedData.container)
        .defaultSize(width: 900, height: 600)
        .defaultPosition(.center)

        Settings {
            SettingsView()
                .environment(appDelegate.clipboardService)
                .environment(appDelegate.syncMonitor)
                .modelContainer(SharedData.container)
        }
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
            "playSounds": true,
            "pasteAndClose": true,
            "cloudSyncEnabled": true,
            "popoverItemCount": 50,
            "maxHistorySize": 5000
        ])
    }()

    let clipboardService: ClipboardService = {
        _ = AppDelegate._registerDefaults
        let maxHistory = UserDefaults.standard.integer(forKey: "maxHistorySize")
        return ClipboardService(maxHistory: maxHistory > 0 ? maxHistory : 5000)
    }()
    let pasteQueue = PasteQueueService()
    let appState = AppState()
    let syncMonitor = SyncMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
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

        // Hide from Dock by default (menu bar only)
        let showInDock = UserDefaults.standard.bool(forKey: "showInDock")
        if !showInDock {
            NSApp.setActivationPolicy(.accessory)
        }

        let ctx = ModelContext(SharedData.container)
        clipboardService.configure(modelContext: ctx)
        clipboardService.start()
        syncMonitor.start()

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
