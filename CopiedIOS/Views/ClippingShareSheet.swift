import SwiftUI
import UIKit
import CopiedKit

/// SwiftUI wrapper around `UIActivityViewController` so any clipping —
/// text, URL, or image — can be routed through iOS' native share sheet
/// from the Clippings list swipe-leading "Share" action.
struct ClippingShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
        // iOS recycles the controller if the array changes; we only
        // present it once per share invocation, so nothing to update.
    }

    /// Pick the best native payload for the clipping's kind: image wins
    /// over URL wins over text, matching the priority the share extension
    /// and detail view already use. Falls back through text → title → raw
    /// URL string so we never hand `UIActivityViewController` an empty
    /// payload (which produces a broken-looking share sheet).
    static func items(for clipping: Clipping) -> [Any] {
        if let data = clipping.imageData, let img = UIImage(data: data) {
            return [img]
        }
        if let urlString = clipping.url,
           let url = URL(string: urlString),
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https",
           url.host?.isEmpty == false {
            return [url]
        }
        if let text = clipping.text, !text.isEmpty {
            return [text]
        }
        if let title = clipping.title, !title.isEmpty {
            return [title]
        }
        if let urlString = clipping.url, !urlString.isEmpty {
            return [urlString]
        }
        return ["(empty clipping)"]
    }
}
