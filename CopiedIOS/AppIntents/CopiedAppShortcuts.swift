import AppIntents
import SwiftData
import UIKit
import CopiedKit

/// Exposes Copied to Siri + the iOS Shortcuts app via the iOS 16+ App
/// Intents framework. Users get voice phrases ("Save clipboard to Copied")
/// and can drop these intents into their own Shortcuts workflows without
/// us writing any SiriKit donations.
///
/// Each intent opens its own `ModelContainer` instance scoped to the
/// main Copied SwiftData store, because App Intents run outside our
/// SwiftUI scene hierarchy and don't have access to the host's injected
/// context.

// MARK: - Shortcuts provider

struct CopiedAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SaveClipboardToCopiedIntent(),
            phrases: [
                "Save clipboard to \(.applicationName)",
                "Save my clipboard to \(.applicationName)"
            ],
            shortTitle: "Save Clipboard",
            systemImageName: "doc.on.clipboard"
        )
        AppShortcut(
            intent: CopyLastClippingIntent(),
            phrases: [
                "Copy last clipping from \(.applicationName)",
                "Paste last clipping from \(.applicationName)"
            ],
            shortTitle: "Copy Last Clipping",
            systemImageName: "arrow.up.doc"
        )
        AppShortcut(
            intent: OpenCopiedIntent(),
            phrases: [
                "Open \(.applicationName)"
            ],
            shortTitle: "Open Copied",
            systemImageName: "app.badge.clock"
        )
    }
}

// MARK: - Shared container accessor

private enum IntentStore {
    /// One-shot lazy. App Intents may fire rapidly from a Shortcut
    /// sequence and the CloudKit-backed ModelContainer is expensive to
    /// construct; sharing it across invocations avoids redundant setup.
    ///
    /// MUST mirror `SharedIOSData.container`'s cloudSync computation
    /// exactly — same UserDefaults keys, same default, same MAS_BUILD
    /// gating — so an intent writes to the same store the host reads.
    /// Codex flagged a MEDIUM here where the defaults diverged (raw
    /// `UserDefaults.standard.bool` returns false for an unset key but
    /// `@AppStorage("cloudSyncEnabled") = true` treats the same unset
    /// state as true). Using `.object(forKey:) as? Bool ?? true` keeps
    /// them aligned.
    ///
    /// Note: this is resolved once per process. A user who toggles
    /// iCloud Sync off while the app is backgrounded will still see
    /// intents write to the CloudKit-backed store until the next cold
    /// launch. That's an explicit trade — rebuilding the container on
    /// every intent invocation is too expensive for a voice shortcut.
    nonisolated(unsafe) static let container: ModelContainer? = {
        let userToggle = UserDefaults.standard.object(forKey: "cloudSyncEnabled") as? Bool ?? true
        #if MAS_BUILD
        let purchased = UserDefaults.standard.bool(forKey: "iCloudSyncPurchased")
        let cloudSync = userToggle && purchased
        #else
        let cloudSync = userToggle
        #endif
        return try? CopiedSchema.makeContainer(cloudSync: cloudSync)
    }()

    @MainActor
    static func context() -> ModelContext? {
        guard let container else { return nil }
        return ModelContext(container)
    }
}

// MARK: - Intents

/// "Hey Siri, save clipboard to Copied" — reads `UIPasteboard.general`,
/// writes a new `Clipping`. Returns a short spoken confirmation.
struct SaveClipboardToCopiedIntent: AppIntent {
    static let title: LocalizedStringResource = "Save Clipboard to Copied"
    static let description = IntentDescription(
        "Captures whatever is on the system clipboard right now and saves it to your Copied history."
    )
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let context = IntentStore.context() else {
            return .result(dialog: "Copied isn't available right now.")
        }
        let pb = UIPasteboard.general
        let clip = Clipping()
        if let image = pb.image {
            let data = image.pngData() ?? Data()
            clip.imageData = data
            clip.hasImage = true
            clip.imageByteCount = data.count
        } else if let url = pb.url {
            clip.url = url.absoluteString
            clip.text = url.absoluteString
        } else if let text = pb.string, !text.isEmpty {
            clip.text = text
        } else {
            return .result(dialog: "Your clipboard is empty.")
        }
        context.insert(clip)
        try context.save()
        return .result(dialog: "Saved to Copied.")
    }
}

/// Writes the most recent (non-trashed) clipping back to the system
/// pasteboard. Handy for one-tap re-paste from a Shortcuts tile.
struct CopyLastClippingIntent: AppIntent {
    static let title: LocalizedStringResource = "Copy Last Clipping"
    static let description = IntentDescription(
        "Copies your most recent Copied clipping back to the system clipboard."
    )
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let context = IntentStore.context() else {
            return .result(dialog: "Copied isn't available right now.")
        }
        var descriptor = FetchDescriptor<Clipping>(
            predicate: #Predicate { $0.deleteDate == nil },
            sortBy: [SortDescriptor(\.addDate, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        guard let latest = try context.fetch(descriptor).first else {
            return .result(dialog: "You don't have any Copied clippings yet.")
        }
        let pb = UIPasteboard.general
        if let data = latest.imageData, let img = UIImage(data: data) {
            pb.image = img
            return .result(dialog: "Copied the latest image from your history.")
        }
        if let text = latest.text ?? latest.url, !text.isEmpty {
            pb.string = text
            return .result(dialog: "Copied the latest clipping from your history.")
        }
        return .result(dialog: "Your latest clipping is empty.")
    }
}

/// Foregrounds the Copied app. Same as tapping the home-screen icon but
/// scriptable from a Shortcut.
struct OpenCopiedIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Copied"
    static let description = IntentDescription("Opens the Copied app.")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        .result()
    }
}
