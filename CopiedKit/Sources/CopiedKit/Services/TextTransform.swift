import Foundation

public enum TextTransform: String, CaseIterable, Identifiable, Sendable {
    case uppercase
    case lowercase
    case titleCase
    case trimWhitespace
    case jsonFormat
    case jsonMinify
    case removeBlankLines
    case sortLines
    case urlEncode
    case urlDecode
    case stripMarkdown

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .uppercase: "UPPERCASE"
        case .lowercase: "lowercase"
        case .titleCase: "Title Case"
        case .trimWhitespace: "Trim Whitespace"
        case .jsonFormat: "JSON: Format"
        case .jsonMinify: "JSON: Minify"
        case .removeBlankLines: "Remove Blank Lines"
        case .sortLines: "Sort Lines"
        case .urlEncode: "URL Encode"
        case .urlDecode: "URL Decode"
        case .stripMarkdown: "Strip Markdown"
        }
    }

    public func apply(_ input: String) -> String {
        switch self {
        case .uppercase:
            return input.uppercased()
        case .lowercase:
            return input.lowercased()
        case .titleCase:
            return input.capitalized
        case .trimWhitespace:
            return input.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        case .jsonFormat:
            return formatJSON(input) ?? input
        case .jsonMinify:
            return minifyJSON(input) ?? input
        case .removeBlankLines:
            return input.components(separatedBy: .newlines)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .joined(separator: "\n")
        case .sortLines:
            return input.components(separatedBy: .newlines)
                .sorted()
                .joined(separator: "\n")
        case .urlEncode:
            return input.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? input
        case .urlDecode:
            return input.removingPercentEncoding ?? input
        case .stripMarkdown:
            return stripMarkdownSyntax(input)
        }
    }

    private func formatJSON(_ input: String) -> String? {
        guard let data = input.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let formatted = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: formatted, encoding: .utf8) else { return nil }
        return str
    }

    private func minifyJSON(_ input: String) -> String? {
        guard let data = input.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let minified = try? JSONSerialization.data(withJSONObject: obj),
              let str = String(data: minified, encoding: .utf8) else { return nil }
        return str
    }

    private func stripMarkdownSyntax(_ input: String) -> String {
        var result = input
        // Headers: # text → text
        result = result.replacingOccurrences(of: "(?m)^#{1,6}\\s+", with: "", options: .regularExpression)
        // Bold: **text** or __text__
        result = result.replacingOccurrences(of: "\\*\\*(.+?)\\*\\*", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "__(.+?)__", with: "$1", options: .regularExpression)
        // Italic: *text* or _text_
        result = result.replacingOccurrences(of: "\\*(.+?)\\*", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "(?<=\\s)_(.+?)_(?=\\s|$)", with: "$1", options: .regularExpression)
        // Inline code: `text`
        result = result.replacingOccurrences(of: "`(.+?)`", with: "$1", options: .regularExpression)
        // Links: [text](url) → text
        result = result.replacingOccurrences(of: "\\[(.+?)\\]\\(.+?\\)", with: "$1", options: .regularExpression)
        // Images: ![alt](url) → alt
        result = result.replacingOccurrences(of: "!\\[(.+?)\\]\\(.+?\\)", with: "$1", options: .regularExpression)
        return result
    }
}
