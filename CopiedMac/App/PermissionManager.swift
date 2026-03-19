import AppKit

/// Checks and prompts for required macOS permissions.
@MainActor
enum PermissionManager {

    private static var hasPromptedThisSession = false

    /// Check accessibility permission (needed for global hotkeys and paste simulation).
    /// If not granted, shows the system prompt and our own explanation.
    /// Only prompts once per app session to avoid nagging during development
    /// (debug rebuilds invalidate TCC entries even when the toggle appears on).
    static func ensureAccessibility() {
        guard !hasPromptedThisSession else { return }
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let trusted = AXIsProcessTrusted()

        if !trusted {
            hasPromptedThisSession = true
            // Trigger the standard system accessibility prompt (the lock icon dialog)
            AXIsProcessTrustedWithOptions(options)
        }
    }

    /// Check if we have accessibility access without prompting.
    static var hasAccessibility: Bool {
        AXIsProcessTrusted()
    }

    private static func showPermissionAlert(title: String, message: String, settingsPane: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let url = URL(string: settingsPane) {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
