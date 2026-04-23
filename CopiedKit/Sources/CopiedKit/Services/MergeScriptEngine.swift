import Foundation

/// A user-defined template that combines multiple clippings into a
/// single string. Token syntax keeps things simple — `{{text}}`,
/// `{{url}}`, `{{title}}` are expanded per clipping, and rows are
/// joined with the `separator` field. Example:
///
///     template:  "- \(title): \(url)"
///     separator: "\n"
///
/// …applied to three bookmark-style clippings gives a markdown list.
public struct MergeScript: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var name: String
    /// Template evaluated once per clipping. Supported tokens: `{{text}}`,
    /// `{{url}}`, `{{title}}`. Unknown tokens are left untouched so users
    /// can mix literal `{{something}}` strings without escaping.
    public var template: String
    /// String inserted between per-clipping expansions. Empty string for
    /// concatenation, `\n` for one-per-line, `", "` for CSV-ish output.
    public var separator: String

    public init(
        id: String = UUID().uuidString,
        name: String,
        template: String,
        separator: String = "\n"
    ) {
        self.id = id
        self.name = name
        self.template = template
        self.separator = separator
    }

    /// Render a single clipping through this template.
    public func render(text: String?, url: String?, title: String?) -> String {
        var out = template
        out = out.replacingOccurrences(of: "{{text}}", with: text ?? "")
        out = out.replacingOccurrences(of: "{{url}}", with: url ?? "")
        out = out.replacingOccurrences(of: "{{title}}", with: title ?? "")
        return out
    }
}

public enum MergeScriptEngine {
    public static let storageKey = "mergeScripts.v1"

    /// Default scripts shipped on first launch so the feature is useful
    /// without requiring the user to hand-write templates. Users can
    /// edit or delete these like any user-defined script.
    public static let defaults: [MergeScript] = [
        MergeScript(
            id: "builtin.newline",
            name: "Join with newlines",
            template: "{{text}}",
            separator: "\n"
        ),
        MergeScript(
            id: "builtin.markdown-list",
            name: "Markdown bullet list",
            template: "- {{text}}",
            separator: "\n"
        ),
        MergeScript(
            id: "builtin.markdown-links",
            name: "Markdown link list",
            template: "- [{{title}}]({{url}})",
            separator: "\n"
        ),
        MergeScript(
            id: "builtin.comma",
            name: "Comma-separated",
            template: "{{text}}",
            separator: ", "
        )
    ]

    public static func load() -> [MergeScript] {
        guard let data = SharedStore.defaults.data(forKey: storageKey) else { return defaults }
        return (try? JSONDecoder().decode([MergeScript].self, from: data)) ?? defaults
    }

    public static func save(_ scripts: [MergeScript]) {
        let data = (try? JSONEncoder().encode(scripts)) ?? Data()
        SharedStore.defaults.set(data, forKey: storageKey)
    }

    /// Produce the merged string for a list of (text, url, title) rows.
    /// Kept free-function-style so callers can pass SwiftData `Clipping`
    /// tuples or preview values without forcing a dependency on the
    /// model module.
    public static func run(
        _ script: MergeScript,
        rows: [(text: String?, url: String?, title: String?)]
    ) -> String {
        rows.map { script.render(text: $0.text, url: $0.url, title: $0.title) }
            .joined(separator: script.separator)
    }
}
