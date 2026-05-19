import Foundation
import SwiftData

#if canImport(AppKit)
import AppKit

public enum ClippingExternalOpenSupport {
    public static let filterKinds: [ContentKind] = [
        .text, .richText, .image, .video, .link, .code, .markdown, .html
    ]

    public static func actionTitle(for clipping: Clipping) -> String? {
        if videoFileURL(for: clipping) != nil {
            return "Open Video"
        }

        switch clipping.contentKind {
        case .link:
            return webURL(for: clipping) == nil ? nil : "Open Link"
        case .code, .markdown, .html:
            return hasText(clipping.text) || clipping.hasHTML || hasText(clipping.extractedText)
                ? "Open in Editor"
                : nil
        case .image:
            return clipping.hasImage ? "Open in Default Viewer" : nil
        case .text, .richText:
            return hasText(clipping.text) || hasText(clipping.extractedText) || clipping.hasRichText
                ? "Open in Default Viewer"
                : nil
        case .file:
            return existingFileURL(from: clipping.sourceURL) == nil ? nil : "Open in Default Viewer"
        case .video, .unknown:
            return nil
        }
    }

    public static func fileExtension(forLanguage language: String?) -> String {
        switch language?.lowercased() {
        case "swift": return "swift"
        case "python": return "py"
        case "javascript", "js": return "js"
        case "typescript", "ts": return "ts"
        case "rust": return "rs"
        case "go": return "go"
        case "java": return "java"
        case "html": return "html"
        case "css": return "css"
        case "shell", "bash", "zsh": return "sh"
        case "yaml", "yml": return "yml"
        case "json": return "json"
        case "toml": return "toml"
        case "dockerfile": return "Dockerfile"
        case "makefile": return "Makefile"
        case "xml": return "xml"
        case "sql": return "sql"
        case "ruby": return "rb"
        case "elixir": return "ex"
        case "kotlin": return "kt"
        case "c": return "c"
        case "cpp", "c++": return "cpp"
        case "php": return "php"
        case "terraform": return "tf"
        case "scala": return "scala"
        case "r": return "R"
        case "lua": return "lua"
        case "dart": return "dart"
        case "haskell": return "hs"
        case "markdown", "md": return "md"
        default: return "txt"
        }
    }

    public static func imageFileExtension(forFormat format: String) -> String {
        switch format.lowercased() {
        case "png": return "png"
        case "jpeg", "jpg": return "jpg"
        case "gif": return "gif"
        case "webp": return "webp"
        case "heic": return "heic"
        default: return "tiff"
        }
    }

    @MainActor
    @discardableResult
    public static func open(_ clipping: Clipping, in container: ModelContainer) -> Bool {
        if let videoURL = videoFileURL(for: clipping) {
            return NSWorkspace.shared.open(videoURL)
        }

        switch clipping.contentKind {
        case .link:
            guard let url = webURL(for: clipping) else { return false }
            return NSWorkspace.shared.open(url)
        case .code, .markdown:
            guard let text = firstText(in: clipping) else { return false }
            return openText(
                text,
                fileExtension: fileExtension(forLanguage: clipping.detectedLanguage),
                prefix: "snippet"
            )
        case .html:
            if let text = clipping.text, !text.isEmpty {
                return openText(text, fileExtension: "html", prefix: "html")
            }
            if clipping.hasHTML,
               let data = ClipboardService.readBlob(
                   in: container,
                   clippingID: clipping.clippingID,
                   key: \Clipping.htmlData
               ) {
                return writeAndOpen(data, fileExtension: "html", prefix: "html")
            }
            guard let text = firstText(in: clipping) else { return false }
            return openText(text, fileExtension: "txt", prefix: "text")
        case .image:
            guard clipping.hasImage,
                  let data = ClipboardService.readBlob(
                      in: container,
                      clippingID: clipping.clippingID,
                      key: \Clipping.imageData
                  ) else { return false }
            return writeAndOpen(
                data,
                fileExtension: imageFileExtension(forFormat: clipping.imageFormat),
                prefix: "image"
            )
        case .richText:
            if clipping.hasRichText,
               let data = ClipboardService.readBlob(
                   in: container,
                   clippingID: clipping.clippingID,
                   key: \Clipping.richTextData
               ) {
                let ext = clipping.richTextPasteboardType == .rtfd ? "rtfd" : "rtf"
                return writeAndOpen(data, fileExtension: ext, prefix: "rich-text")
            }
            guard let text = firstText(in: clipping) else { return false }
            return openText(text, fileExtension: "txt", prefix: "text")
        case .text:
            guard let text = firstText(in: clipping) else { return false }
            return openText(text, fileExtension: "txt", prefix: "text")
        case .file:
            guard let url = existingFileURL(from: clipping.sourceURL) else { return false }
            return NSWorkspace.shared.open(url)
        case .video, .unknown:
            return false
        }
    }

    private static func hasText(_ text: String?) -> Bool {
        guard let text else { return false }
        return !text.isEmpty
    }

    private static func firstText(in clipping: Clipping) -> String? {
        if hasText(clipping.text) { return clipping.text }
        if hasText(clipping.extractedText) { return clipping.extractedText }
        return nil
    }

    private static func webURL(for clipping: Clipping) -> URL? {
        guard let raw = clipping.url,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    private static func videoFileURL(for clipping: Clipping) -> URL? {
        guard clipping.isVideoFile else { return nil }
        return existingFileURL(from: clipping.sourceURL)
    }

    private static func existingFileURL(from rawURL: String?) -> URL? {
        guard let rawURL,
              let url = URL(string: rawURL),
              url.isFileURL,
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    @MainActor
    private static func openText(_ text: String, fileExtension: String, prefix: String) -> Bool {
        writeAndOpen(Data(text.utf8), fileExtension: fileExtension, prefix: prefix)
    }

    @MainActor
    private static func writeAndOpen(_ data: Data, fileExtension: String, prefix: String) -> Bool {
        let slug = UUID().uuidString.prefix(8)
        let url = ClipboardService.quickLookCacheDirectory()
            .appendingPathComponent("\(prefix)-\(slug).\(fileExtension)")
        do {
            try data.write(to: url, options: .atomic)
            return NSWorkspace.shared.open(url)
        } catch {
            NSLog("Failed to write clipping preview file: \(error)")
            return false
        }
    }
}
#endif
