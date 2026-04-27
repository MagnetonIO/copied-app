import UIKit
import Social
import UniformTypeIdentifiers
import CopiedKit

/// Host for the iOS share sheet's "Save to Copied" action.
///
/// `SLComposeServiceViewController` gives us the standard compose UI (preview
/// thumbnail, editable text box, Cancel / Post buttons) for free. We parse
/// `extensionContext.inputItems` up front so `isContentValid` can reflect
/// whatever the user is sharing, and `didSelectPost` writes one
/// `PendingClipping` to the App Group inbox. The host app drains the inbox on
/// `ScenePhase.active` and inserts rows into SwiftData there, so the
/// extension never opens the SwiftData container itself (cross-process
/// SwiftData access is unsupported).
final class ShareViewController: SLComposeServiceViewController {

    private var sharedURL: URL?
    private var sharedText: String?
    private var sharedImageData: Data?
    private var sharedTitle: String?
    private var pendingProviderLoads = 0

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Save to Copied"
        placeholder = "Add a note (optional)"
        // SLComposeServiceViewController auto-fills `textView.text` from the
        // incoming NSExtensionItem.attributedContentText (typically the page
        // title). That's ambiguous UX — users can't tell whether the note
        // box belongs to them or contains preview text. Blank it so the
        // placeholder shows and the page title surfaces in the read-only
        // "Link"/"Title" configuration row below instead.
        textView.text = ""
        loadSharedPayload()
    }

    // MARK: - Input item parsing

    /// Walks the incoming items and captures URL / image / text payloads.
    /// Tracks outstanding async loads so the Post button only enables after
    /// they complete.
    private func loadSharedPayload() {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else { return }
        for item in items {
            if let title = item.attributedContentText?.string, sharedTitle == nil {
                sharedTitle = title
            }
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    pendingProviderLoads += 1
                    provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { [weak self] item, _ in
                        let url = item as? URL
                        Task { @MainActor in
                            self?.sharedURL = url
                            self?.finishProviderLoad()
                        }
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    pendingProviderLoads += 1
                    provider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { [weak self] item, _ in
                        let data: Data?
                        if let imageURL = item as? URL {
                            data = try? Data(contentsOf: imageURL)
                        } else if let image = item as? UIImage {
                            data = image.pngData()
                        } else if let raw = item as? Data {
                            data = raw
                        } else {
                            data = nil
                        }
                        Task { @MainActor in
                            self?.sharedImageData = data
                            self?.finishProviderLoad()
                        }
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    pendingProviderLoads += 1
                    provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { [weak self] item, _ in
                        let text = item as? String
                        Task { @MainActor in
                            if let text, self?.sharedText == nil { self?.sharedText = text }
                            self?.finishProviderLoad()
                        }
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.text.identifier) {
                    pendingProviderLoads += 1
                    provider.loadItem(forTypeIdentifier: UTType.text.identifier, options: nil) { [weak self] item, _ in
                        let text = (item as? String) ?? (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
                        Task { @MainActor in
                            if let text, self?.sharedText == nil { self?.sharedText = text }
                            self?.finishProviderLoad()
                        }
                    }
                }
            }
        }
        reloadConfigurationItems()
    }

    @MainActor
    private func finishProviderLoad() {
        pendingProviderLoads = max(0, pendingProviderLoads - 1)
        validateContent()
        reloadConfigurationItems()
    }

    // MARK: - SLComposeServiceViewController

    /// Enable Post button once outstanding async loads finish AND we have
    /// something worth saving.
    override func isContentValid() -> Bool {
        guard pendingProviderLoads == 0 else { return false }
        if sharedURL != nil || sharedImageData != nil { return true }
        let note = contentText.trimmingCharacters(in: .whitespacesAndNewlines)
        let shared = sharedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !note.isEmpty || !shared.isEmpty
    }

    override func didSelectPost() {
        let userNote = contentText.trimmingCharacters(in: .whitespacesAndNewlines)
        let text: String?
        if !userNote.isEmpty {
            text = userNote
        } else if let shared = sharedText, !shared.isEmpty {
            text = shared
        } else if let title = sharedTitle, !title.isEmpty, sharedURL != nil {
            text = title
        } else {
            text = nil
        }

        let pending = SharedStore.PendingClipping(
            text: text,
            url: sharedURL?.absoluteString,
            title: sharedTitle,
            imageData: sharedImageData,
            source: .share
        )

        do {
            try SharedStore.enqueue(pending)
            // Subtle tactile confirmation before the sheet dismisses —
            // matches Apple Notes / Mail / Twitter share-extension UX.
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        } catch {
            NSLog("CopiedShareExtension: failed to enqueue: \(error)")
            let wrapped = NSError(
                domain: "com.magneton.copied.ShareExtension",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Couldn't save to Copied. Please try again."]
            )
            extensionContext?.cancelRequest(withError: wrapped)
        }
    }

    /// Read-only row below the note box so the user sees exactly what's
    /// being saved (hostname, image size, or text preview). Doubles as a
    /// loading indicator while async item-provider loads are in flight —
    /// the SLComposeServiceViewController has no spinner slot, so a
    /// "Loading…" value in this row is the cleanest available signal.
    override func configurationItems() -> [Any]! {
        guard let item = SLComposeSheetConfigurationItem() else { return [] }
        if pendingProviderLoads > 0 {
            item.title = "Status"
            item.value = "Loading…"
        } else if let url = sharedURL {
            item.title = "Link"
            item.value = url.host ?? url.absoluteString
        } else if let data = sharedImageData {
            item.title = "Image"
            item.value = "\(max(1, data.count / 1024)) KB"
        } else if let text = sharedText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            item.title = "Text"
            let preview = String(text.prefix(40))
            item.value = text.count > 40 ? "\(preview)…" : preview
        } else if let title = sharedTitle, !title.isEmpty {
            item.title = "Title"
            item.value = title
        } else {
            item.title = "Clipping"
            item.value = "Empty"
        }
        // Leaving tapHandler unset — the row is read-only; setting it to
        // an empty closure would register as an actionable element for
        // VoiceOver and touch, which confuses screen-reader users.
        return [item]
    }
}
