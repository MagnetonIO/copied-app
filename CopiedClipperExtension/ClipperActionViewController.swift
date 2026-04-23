import UIKit
import Social
import UniformTypeIdentifiers
import CopiedKit

/// Host for the Safari "Copied Clipper" action. The companion JavaScript
/// file (`ClipperPreprocess.js`) runs in the page context before this
/// controller loads, capturing `document.title`, `window.location.href`,
/// and `window.getSelection().toString()`. Safari packages those as a
/// `com.apple.property-list` attachment on the input item, which we
/// decode here to pre-fill the compose sheet.
///
/// Unlike "Save to Copied", the user's selection IS the primary payload
/// — the note box is the optional annotation. So the compose sheet shows
/// the selection (truncated preview) in the `configurationItems` status
/// row and leaves the note box empty for annotation.
final class ClipperActionViewController: SLComposeServiceViewController {

    private var pageTitle: String?
    private var pageURL: URL?
    private var pageSelection: String?
    private var pendingProviderLoads = 0

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Copied Clipper"
        placeholder = "Add a note (optional)"
        // Same rationale as ShareViewController: keep the note box
        // unambiguously the user's. We surface the page context via the
        // read-only configuration row below instead.
        textView.text = ""
        loadPreprocessResults()
    }

    // MARK: - Preprocessing-results decode

    /// Walks the incoming items looking for Safari's preprocessing plist
    /// first (rich capture: title + URL + selection), then falls back to
    /// a plain `public.url` NSItemProvider that non-Safari browsers
    /// (Chrome, Firefox, Google Search, Messages, Mail, etc.) use when
    /// sharing a link. The item title, if supplied, fills `pageTitle`.
    private func loadPreprocessResults() {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else { return }
        var loadedSafariPlist = false
        for item in items {
            // Non-Safari callers often set `attributedContentText` or
            // `attributedTitle` on the NSExtensionItem — lift that into
            // `pageTitle` as a best-effort guess before provider loads
            // complete. Safari's plist will overwrite if present.
            if let titled = item.attributedTitle?.string.trimmingCharacters(in: .whitespacesAndNewlines),
               !titled.isEmpty, pageTitle == nil {
                pageTitle = titled
            }
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.propertyList.identifier) {
                    loadedSafariPlist = true
                    pendingProviderLoads += 1
                    provider.loadItem(forTypeIdentifier: UTType.propertyList.identifier, options: nil) { [weak self] loaded, _ in
                        let results = (loaded as? [String: Any])?[NSExtensionJavaScriptPreprocessingResultsKey] as? [String: Any]
                        let title = (results?["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                        let urlString = (results?["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                        let selection = (results?["selection"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                        Task { @MainActor in
                            if let t = title, !t.isEmpty { self?.pageTitle = t }
                            if let urlString, let url = URL(string: urlString), url.scheme == "http" || url.scheme == "https" {
                                self?.pageURL = url
                            }
                            self?.pageSelection = (selection?.isEmpty == false) ? selection : nil
                            self?.finishProviderLoad()
                        }
                    }
                }
            }
        }
        // Non-Safari fallback — only walked if no preprocessing plist was
        // attached. Looks for a direct public.url item provider (every
        // browser except Safari shares URLs this way).
        if !loadedSafariPlist {
            for item in items {
                for provider in item.attachments ?? [] {
                    guard provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) else { continue }
                    pendingProviderLoads += 1
                    provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { [weak self] loaded, _ in
                        // `loaded` is typically a URL, but some apps
                        // wrap it as NSString. Handle both.
                        let resolved: URL? = {
                            if let url = loaded as? URL { return url }
                            if let s = loaded as? String { return URL(string: s) }
                            return nil
                        }()
                        Task { @MainActor in
                            if let url = resolved,
                               let scheme = url.scheme?.lowercased(),
                               scheme == "http" || scheme == "https" {
                                self?.pageURL = url
                            }
                            self?.finishProviderLoad()
                        }
                    }
                    break // one URL per item is plenty
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

    override func isContentValid() -> Bool {
        guard pendingProviderLoads == 0 else { return false }
        // A clip needs a URL at minimum (what makes it a clip vs. a
        // freeform note). Selection + note are both optional.
        return pageURL != nil
    }

    override func didSelectPost() {
        let userNote = contentText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Priority: user note > captured selection > page title fallback.
        let text: String?
        if !userNote.isEmpty {
            text = userNote
        } else if let sel = pageSelection, !sel.isEmpty {
            text = sel
        } else if let t = pageTitle, !t.isEmpty {
            text = t
        } else {
            text = nil
        }

        let pending = SharedStore.PendingClipping(
            text: text,
            url: pageURL?.absoluteString,
            title: pageTitle,
            imageData: nil,
            source: .clipper
        )

        do {
            try SharedStore.enqueue(pending)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        } catch {
            NSLog("CopiedClipperExtension: failed to enqueue: \(error)")
            let wrapped = NSError(
                domain: "com.mlong.copied.ClipperAction",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Couldn't save to Copied. Please try again."]
            )
            extensionContext?.cancelRequest(withError: wrapped)
        }
    }

    override func configurationItems() -> [Any]! {
        guard let item = SLComposeSheetConfigurationItem() else { return [] }
        if pendingProviderLoads > 0 {
            item.title = "Status"
            item.value = "Loading…"
        } else if let sel = pageSelection, !sel.isEmpty {
            item.title = "Selection"
            let preview = String(sel.prefix(40))
            item.value = sel.count > 40 ? "\(preview)…" : preview
        } else if let url = pageURL {
            item.title = "Link"
            item.value = url.host ?? url.absoluteString
        } else if let t = pageTitle, !t.isEmpty {
            item.title = "Title"
            item.value = t
        } else {
            item.title = "Clip"
            item.value = "Empty"
        }
        // Intentionally no tapHandler — this row is read-only; a closure
        // would register as actionable to VoiceOver.
        return [item]
    }
}
