import Foundation
import NaturalLanguage

public struct CodeDetector: Sendable {

    /// Tier 0 disqualifier: if NLTagger says the text is mostly natural
    /// English (≥ 70% of words tagged as nouns/verbs/adjectives/etc.), skip
    /// every code-detection pass. Catches the entire class of "prose
    /// mentioning programming concepts gets tagged as that language" bugs
    /// — e.g. "Defer until next week" matching Zig, "Auto-update" matching
    /// SQL, "Lambda calculus: …" matching Python.
    ///
    /// Cost: ~1-5 ms per call on a 500-char snippet (off-main, in
    /// `processCapture` Phase B). NLTagger initializes lazily — first call
    /// per process pays a ~50 ms model load; subsequent calls are fast.
    public static func looksLikeProseNL(_ text: String) -> Bool {
        guard text.count >= 50 else { return false }
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        var natural = 0
        var total = 0
        let opts: NLTagger.Options = [.omitWhitespace, .omitPunctuation]
        let proseTags: Set<NLTag> = [
            .noun, .verb, .adjective, .adverb,
            .pronoun, .determiner, .preposition, .conjunction
        ]
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word, scheme: .lexicalClass, options: opts
        ) { tag, _ in
            total += 1
            if let tag, proseTags.contains(tag) {
                natural += 1
            }
            return true
        }
        return total > 0 && Double(natural) / Double(total) > 0.7
    }

    public struct Result: Sendable {
        public let isCode: Bool
        public let language: String?
        public let confidence: Double
    }

    public static func detect(in text: String) -> Result {
        // Cap to keep main-actor finalize predictable. Keyword/regex pass over
        // a 100 KB log file is wasted work — return a neutral result.
        guard text.count <= 64_000 else {
            return Result(isCode: false, language: nil, confidence: 0)
        }

        // Quick structural check for config/data formats (YAML, JSON, TOML, etc.)
        // These have distinct patterns that the general heuristics miss
        if let configLang = detectConfigFormat(text) {
            return Result(isCode: true, language: configLang, confidence: 0.8)
        }

        var score: Double = 0
        var language: String?

        // Negative: too short
        if text.count < 30 {
            score -= 0.3
        }

        // Negative: prose-like (high ratio of spaces to non-spaces)
        let spaceCount = text.filter({ $0 == " " }).count
        let nonSpaceCount = text.count - spaceCount
        if nonSpaceCount > 0 {
            let spaceRatio = Double(spaceCount) / Double(nonSpaceCount)
            if spaceRatio > 0.35 { score -= 0.2 }
        }

        // Shebang — immediate strong signal
        if text.hasPrefix("#!") {
            score += 0.5
            if language == nil { language = detectShebangLanguage(text) }
        }

        // Indentation patterns (2+ lines with leading whitespace)
        let lines = text.components(separatedBy: .newlines)
        let indentedLines = lines.filter { $0.hasPrefix("  ") || $0.hasPrefix("\t") }
        if indentedLines.count >= 2 {
            score += 0.2
        }

        // Bracket density
        let brackets = text.filter { "{}[]()".contains($0) }
        if text.count > 0 {
            let bracketRatio = Double(brackets.count) / Double(text.count)
            if bracketRatio > 0.02 { score += 0.15 }
        }

        // Semicolons at end of line
        let semicolonLines = lines.filter { $0.trimmingCharacters(in: .whitespaces).hasSuffix(";") }
        if semicolonLines.count >= 2 { score += 0.15 }

        // Comment patterns
        let commentLines = lines.filter {
            let trimmed = $0.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("//") || trimmed.hasPrefix("/*") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("#") && !trimmed.hasPrefix("#!")
        }
        if commentLines.count >= 1 { score += 0.1 }

        // Language keyword detection (+0.3, also sets language)
        let detected = detectLanguageByKeywords(text)
        if let detected {
            score += 0.3
            if language == nil { language = detected }
        }

        let isCode = score >= 0.6
        return Result(isCode: isCode, language: isCode ? language : nil, confidence: min(max(score, 0), 1))
    }

    // MARK: - Config/Data Format Detection

    /// Detects structured config formats that general heuristics miss.
    /// These formats use indentation + key-value patterns rather than brackets/semicolons.
    /// Public alias for `detectConfigFormat` so the categorization
    /// pipeline can run config-format detection (YAML/JSON/TOML/Dockerfile/
    /// Makefile) at a higher priority than the markdown heuristic. Without
    /// this, YAML lists with `- item` entries + `---` separators were
    /// scoring high enough on the markdown bullet/HR rules to be tagged
    /// markdown before the config detector got a chance.
    public static func configLanguage(in text: String) -> String? {
        detectConfigFormat(text)
    }

    private static func detectConfigFormat(_ text: String) -> String? {
        let lines = text.components(separatedBy: .newlines)
        let nonEmptyLines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard nonEmptyLines.count >= 3 else { return nil }

        // Disqualifier: if the text contains lines starting with code-language
        // keywords, it is NOT a config file. Python type annotations like
        // `x: int = 5` and `self.foo = bar` otherwise look like YAML/TOML
        // key:value lines and falsely trigger the structural detector.
        // Real YAML / TOML / Dockerfile / Makefile never start lines with
        // these tokens.
        let codeLines = nonEmptyLines.filter { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            // Python
            if t.hasPrefix("def ") || t.hasPrefix("class ") || t.hasPrefix("async def ") { return true }
            if t.hasPrefix("from ") && t.contains(" import ") { return true }
            if t.hasPrefix("self.") || t.hasPrefix("cls.") { return true }
            // Swift / Rust / Kotlin / Go
            if t.hasPrefix("import ") || t.hasPrefix("use ") || t.hasPrefix("package ") { return true }
            if t.hasPrefix("func ") || t.hasPrefix("fn ") { return true }
            if t.hasPrefix("struct ") || t.hasPrefix("enum ") || t.hasPrefix("protocol ") { return true }
            // JS / TS
            if t.hasPrefix("function ") || t.hasPrefix("const ") || t.hasPrefix("export ") { return true }
            // Decorators / annotations (Python @, Swift @, Java @, TS @)
            if t.hasPrefix("@") && t.count > 1 {
                return t[t.index(after: t.startIndex)].isLetter
            }
            return false
        }
        if codeLines.count >= 1 {
            return nil
        }

        // YAML: lines matching "key: value" or "- item" pattern, with indentation
        let yamlKeyValue = nonEmptyLines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // key: value (but not URLs like http:// or times like 12:30)
            if let colonRange = trimmed.range(of: ":"),
               colonRange.lowerBound > trimmed.startIndex,
               !trimmed.contains("://") {
                let beforeColon = trimmed[trimmed.startIndex..<colonRange.lowerBound]
                // Key must be a simple identifier (letters, numbers, underscores, hyphens)
                return beforeColon.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." }
            }
            // List item: "- something"
            if trimmed.hasPrefix("- ") { return true }
            return false
        }
        // Two ways to qualify as YAML:
        //   1. ≥ 3 key:value lines AND > 50% of total lines (strict)
        //   2. ≥ 2 key:value lines AND > 30% (loose — covers small files
        //      and YAML with embedded `run: |` shell blocks where the
        //      embedded content drags the structural ratio down)
        if (yamlKeyValue.count >= 3 && Double(yamlKeyValue.count) / Double(nonEmptyLines.count) > 0.5) ||
           (yamlKeyValue.count >= 2 && Double(yamlKeyValue.count) / Double(nonEmptyLines.count) > 0.3) {
            return "yaml"
        }

        // JSON: starts with { or [, has quoted keys
        let trimmedFull = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if (trimmedFull.hasPrefix("{") && trimmedFull.hasSuffix("}")) ||
           (trimmedFull.hasPrefix("[") && trimmedFull.hasSuffix("]")) {
            let quotedKeys = nonEmptyLines.filter { $0.contains("\"") && $0.contains(":") }
            if quotedKeys.count >= 2 {
                return "json"
            }
        }

        // TOML: [section] headers and key = value pairs
        let tomlSections = nonEmptyLines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("[") && trimmed.hasSuffix("]") && !trimmed.hasPrefix("[[")
                || trimmed.hasPrefix("[[") && trimmed.hasSuffix("]]")
        }
        let tomlKeyValue = nonEmptyLines.filter { $0.contains(" = ") }
        if tomlSections.count >= 1 && tomlKeyValue.count >= 2 {
            return "toml"
        }

        // Dockerfile: FROM, RUN, COPY, ENV, CMD, ENTRYPOINT, WORKDIR, EXPOSE, ARG
        let dockerKeywords = ["FROM ", "RUN ", "COPY ", "ENV ", "CMD ", "ENTRYPOINT ", "WORKDIR ", "EXPOSE ", "ARG ", "ADD ", "LABEL "]
        let dockerMatches = dockerKeywords.filter { kw in nonEmptyLines.contains { $0.hasPrefix(kw) } }
        if dockerMatches.count >= 2 {
            return "dockerfile"
        }

        // Makefile: targets with ":" and recipe lines starting with tab
        let makeTargets = nonEmptyLines.filter { line in
            !line.hasPrefix("\t") && !line.hasPrefix(" ") && line.contains(":") && !line.contains(":=")
        }
        let makeRecipes = lines.filter { $0.hasPrefix("\t") }
        if makeTargets.count >= 1 && makeRecipes.count >= 1 {
            return "makefile"
        }

        return nil
    }

    private static func detectShebangLanguage(_ text: String) -> String? {
        let firstLine = String(text.prefix(while: { $0 != "\n" })).lowercased()
        if firstLine.contains("python") { return "python" }
        if firstLine.contains("node") || firstLine.contains("deno") { return "javascript" }
        if firstLine.contains("ruby") { return "ruby" }
        if firstLine.contains("bash") || firstLine.contains("sh") { return "shell" }
        if firstLine.contains("perl") { return "perl" }
        return nil
    }

    private static func detectLanguageByKeywords(_ text: String) -> String? {
        struct LanguagePattern {
            let name: String
            let keywords: [String]
            let minMatches: Int
        }

        let patterns: [LanguagePattern] = [
            LanguagePattern(name: "swift", keywords: ["func ", "let ", "var ", "guard ", "import Foundation", "import SwiftUI", "struct ", "enum ", "protocol ", "@Observable", "-> "], minMatches: 3),
            LanguagePattern(name: "python", keywords: ["def ", "import ", "self.", "elif ", "print(", "class ", "__init__", "from ", "None", "True", "False"], minMatches: 3),
            LanguagePattern(name: "javascript", keywords: ["const ", "=> ", "function ", "require(", "module.exports", "async ", "await ", "console.log", "undefined", "==="], minMatches: 3),
            LanguagePattern(name: "typescript", keywords: ["interface ", ": string", ": number", ": boolean", "export ", "import ", "type ", "as ", "readonly "], minMatches: 3),
            LanguagePattern(name: "rust", keywords: ["fn ", "let mut ", "impl ", "pub ", "use ", "match ", "Option<", "Result<", "println!", "&self"], minMatches: 3),
            LanguagePattern(name: "go", keywords: ["func ", "package ", "import (", "fmt.", "err != nil", ":= ", "defer ", "go ", "chan "], minMatches: 3),
            LanguagePattern(name: "java", keywords: ["public class", "private ", "void ", "System.out", "new ", "return ", "throws ", "@Override", "import java."], minMatches: 3),
            LanguagePattern(name: "html", keywords: ["<html", "<div", "<span", "<body", "<!DOCTYPE", "<head", "<script", "</"], minMatches: 3),
            LanguagePattern(name: "css", keywords: ["color:", "margin:", "padding:", "display:", "font-size:", "background:", "{", "}"], minMatches: 3),
            // Shell — was matching YAML literal blocks ("| ") and generic
            // "export " / "done" in non-shell content. Shebang or "if [...]"
            // bracket syntax are the only truly distinctive shell shapes;
            // require 4 matches and drop the ambiguous tokens.
            LanguagePattern(name: "shell", keywords: ["#!/bin", "echo \"", "echo '", "if [ ", "fi\n", "chmod +", "grep -", "$(", "${"], minMatches: 4),
            LanguagePattern(name: "xml", keywords: ["<?xml", "<!", "xmlns", "/>", "</"], minMatches: 2),
            LanguagePattern(name: "sql", keywords: ["SELECT ", "FROM ", "WHERE ", "INSERT ", "UPDATE ", "CREATE TABLE", "ALTER ", "DROP ", "JOIN "], minMatches: 2),
            LanguagePattern(name: "ruby", keywords: ["def ", "end", "puts ", "require ", "class ", "attr_", "do |", ".each ", "nil", "elsif"], minMatches: 3),
            LanguagePattern(name: "elixir", keywords: ["defmodule ", "def ", "do", "end", "|> ", "defp ", "@moduledoc", "@doc", "IO.puts", "Enum.", "fn ", "case "], minMatches: 3),
            LanguagePattern(name: "kotlin", keywords: ["fun ", "val ", "var ", "class ", "import ", "when ", "suspend ", "sealed ", "data class", "override ", "companion object"], minMatches: 3),
            LanguagePattern(name: "c", keywords: ["#include", "int main", "printf(", "void ", "sizeof(", "malloc(", "NULL", "typedef ", "struct ", "#define "], minMatches: 3),
            LanguagePattern(name: "cpp", keywords: ["#include", "std::", "cout", "cin", "namespace ", "template", "class ", "virtual ", "nullptr", "auto "], minMatches: 3),
            LanguagePattern(name: "php", keywords: ["<?php", "echo ", "$", "function ", "->", "=>", "namespace ", "use ", "class ", "public function"], minMatches: 3),
            LanguagePattern(name: "terraform", keywords: ["resource ", "variable ", "output ", "provider ", "module ", "data ", "locals ", "terraform "], minMatches: 2),
            LanguagePattern(name: "scala", keywords: ["object ", "def ", "val ", "var ", "trait ", "case class", "import ", "extends ", "override "], minMatches: 3),
            LanguagePattern(name: "r", keywords: ["<- ", "library(", "function(", "data.frame", "ggplot", "c(", "print(", "if (", "for ("], minMatches: 3),
            LanguagePattern(name: "lua", keywords: ["local ", "function ", "end", "then", "elseif", "require(", "nil", "pairs(", "ipairs("], minMatches: 3),
            LanguagePattern(name: "dart", keywords: ["void ", "Widget ", "class ", "final ", "const ", "@override", "setState(", "import ", "return "], minMatches: 3),
            LanguagePattern(name: "haskell", keywords: ["module ", "import ", "where", "data ", "type ", "class ", "instance ", "do", "let ", "in "], minMatches: 3),
        ]

        var bestMatch: String?
        var bestCount = 0

        for pattern in patterns {
            let matchCount = pattern.keywords.filter { text.contains($0) }.count
            if matchCount >= pattern.minMatches && matchCount > bestCount {
                bestCount = matchCount
                bestMatch = pattern.name
            }
        }

        return bestMatch
    }

    // MARK: - UTI / Markdown / HTML triage

    /// Map well-known source-code UTIs (declared by the OS or app
    /// bundles) to a language tag. Stronger signal than text heuristics —
    /// the pasteboard is *telling* us the content is source code.
    public static func languageFromUTIs(_ types: [String]) -> String? {
        let map: [String: String] = [
            "public.swift-source": "swift",
            "public.python-script": "python",
            "public.objective-c-source": "objective-c",
            "public.objective-c-plus-plus-source": "objective-c",
            "public.c-source": "c",
            "public.c-plus-plus-source": "cpp",
            "public.c-header": "c",
            "public.javascript-source": "javascript",
            "public.shell-script": "shell",
            "public.perl-script": "perl",
            "public.ruby-script": "ruby",
            "public.php-script": "php",
            "public.xml": "xml",
            "public.json": "json",
            "public.yaml": "yaml",
            "public.css": "css",
        ]
        for type in types { if let lang = map[type] { return lang } }
        if types.contains("public.source-code") { return "code" }
        return nil
    }

    /// Heuristic markdown detector. Tuned to fire on
    /// ChatGPT/Notion/Bear/Obsidian output (the typical sources) but not
    /// on prose that happens to use a hyphen or asterisk once. Threshold
    /// is `score >= 3`, which roughly means "two clear markdown features
    /// or one strong one (heading + bullets, fenced code, link)".
    public static func looksLikeMarkdown(_ text: String) -> Bool {
        guard text.count >= 30 else { return false }
        // Don't burn regex/line-scan time on huge pasted dumps. Categorization
        // for a 100 KB log file is meaningless anyway.
        guard text.count <= 64_000 else { return false }
        let lines = text.components(separatedBy: .newlines)
        let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        // YAML / TOML disqualifier. These config formats heavily use
        // `- item` lists (markdown bullet pattern) and `---` document
        // separators (markdown horizontal rule), which were enough to
        // tip them past the markdown threshold. If 40%+ of non-empty
        // lines look like `simple_key: value` (a YAML/TOML hallmark),
        // bail out so the config detector can claim it.
        let yamlKeyValueLines = nonEmpty.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let colonIdx = trimmed.firstIndex(of: ":"),
                  colonIdx > trimmed.startIndex,
                  !trimmed.contains("://") else { return false }
            let key = trimmed[trimmed.startIndex..<colonIdx]
            return key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." }
        }
        if !nonEmpty.isEmpty,
           Double(yamlKeyValueLines.count) / Double(nonEmpty.count) > 0.4 {
            return false
        }

        var score = 0

        if lines.contains(where: { $0.range(of: #"^#{1,6}\s"#, options: .regularExpression) != nil }) {
            score += 2
        }
        let bulletLines = lines.filter { $0.range(of: #"^\s*[-*+]\s"#, options: .regularExpression) != nil }
        if bulletLines.count >= 2 { score += 2 }
        let numberedLines = lines.filter { $0.range(of: #"^\s*\d+[.)]\s"#, options: .regularExpression) != nil }
        if numberedLines.count >= 2 { score += 2 }
        if text.range(of: #"\*\*[^*\n]{2,}\*\*"#, options: .regularExpression) != nil { score += 1 }
        if text.range(of: #"(?<!\*)\*[^*\n]{2,}\*(?!\*)"#, options: .regularExpression) != nil { score += 1 }
        if text.range(of: #"`[^`\n]+`"#, options: .regularExpression) != nil { score += 1 }
        if text.contains("```") { score += 2 }
        if text.range(of: #"\[[^\]]+\]\([^\)]+\)"#, options: .regularExpression) != nil { score += 2 }
        if lines.contains(where: { $0.hasPrefix("> ") }) { score += 1 }
        if lines.contains(where: {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return t == "---" || t == "***"
        }) { score += 1 }

        return score >= 3
    }

    /// Returns true when the HTML is just a plain-text wrapper (meta + p
    /// + span etc.) rather than rich page structure. ChatGPT/Notion/Bear
    /// drop a `public.html` payload alongside their plain text just to
    /// preserve the styling — the *real* content is the plain text. We
    /// use this to demote `hasHTML` rows to whatever the text looks like
    /// (typically markdown).
    public static func htmlIsTrivialWrapper(_ html: String) -> Bool {
        let lower = html.lowercased()
        let richTags = ["<table", "<ul", "<ol", "<script", "<style", "<img",
                        "<a ", "<h1", "<h2", "<h3", "<pre", "<code", "<blockquote"]
        return !richTags.contains { lower.contains($0) }
    }

    /// High-confidence anchor patterns for the top languages. Returns a
    /// language tag if the text contains a structural marker that's
    /// extremely unlikely outside source code (e.g. `import java.`,
    /// `^def \w+\(`, `<!DOCTYPE html>`). Used as Tier 1 of the detector,
    /// before the keyword heuristic — anchors fire on short snippets
    /// (one function, one import) that the keyword heuristic misses.
    public static func anchorLanguage(in text: String) -> String? {
        // Hard cap on text size — running ~80 regex matches over a 100 KB
        // dump is a frame-budget killer with no useful payoff (huge pastes
        // are almost never single-language code snippets).
        guard text.count <= 64_000 else { return nil }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)

        // Tier 1 (strong anchors): patterns with structural shape that's
        // extremely unlikely outside source code (e.g. `<?php`, `<!DOCTYPE`,
        // `import Foundation`, shebang lines). A single match is enough.
        for (lang, regex) in compiledStrongAnchors {
            if regex.firstMatch(in: text, options: [], range: range) != nil {
                return lang
            }
        }

        // Tier 2 (weak anchors): bare-keyword patterns that overlap with
        // common English words (UPDATE, lambda, defer, end, type X =).
        // Require ≥ 2 DISTINCT weak anchors of the same language before
        // tagging. Single matches fall through to the keyword heuristic
        // (which already requires ≥ 3 keyword matches).
        var hitsByLang: [String: Int] = [:]
        for (lang, regex) in compiledWeakAnchors {
            if regex.firstMatch(in: text, options: [], range: range) != nil {
                hitsByLang[lang, default: 0] += 1
            }
        }
        if let best = hitsByLang.max(by: { $0.value < $1.value }), best.value >= 2 {
            return best.key
        }
        return nil
    }

    /// Compiled once at class-init. Two-tier classification:
    ///
    /// - **Strong**: structural patterns that don't appear in English prose
    ///   (`<?php`, `<!DOCTYPE`, `import Foundation`, shebangs, `@import("std")`,
    ///   typed function signatures with `->`). Single match → return the lang.
    /// - **Weak**: bare-keyword patterns that overlap with common English
    ///   words (UPDATE, lambda, defer, end, type X =). Need ≥ 2 distinct
    ///   weak anchors of the same language before tagging — prevents prose
    ///   like "Auto-update" from matching SQL or "Defer until..." matching Zig.
    ///
    /// Both lists are compiled CASE-SENSITIVELY — was case-insensitive
    /// before, which let prose lowercase words match uppercase code keywords.
    private static let compiledStrongAnchors: [(language: String, regex: NSRegularExpression)] = {
        compile(strongAnchorPatterns)
    }()
    private static let compiledWeakAnchors: [(language: String, regex: NSRegularExpression)] = {
        compile(weakAnchorPatterns)
    }()

    private static func compile(_ patterns: [(String, String)]) -> [(language: String, regex: NSRegularExpression)] {
        patterns.compactMap { (lang, pattern) in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return (lang, regex)
        }
    }

    /// Strong anchors — structural shape that essentially never appears in
    /// natural-language prose. Order matters: more specific first so e.g.
    /// Objective-C wins over plain C, TypeScript wins over JavaScript.
    private static let strongAnchorPatterns: [(String, String)] = [
        // Objective-C — @interface/@implementation/@protocol + identifier
        ("objective-c", #"@(interface|implementation|protocol)\s+\w+"#),
        ("objective-c", #"^\s*#import\s*[<"]"#),
        // Swift — Apple framework imports + typed signatures
        ("swift",      #"^\s*import\s+(Foundation|SwiftUI|UIKit|AppKit|Combine|SwiftData|CoreData|CloudKit|XCTest)"#),
        ("swift",      #"\bfunc\s+\w+\s*(<[^>]+>)?\s*\([^)]*\)\s*(async\s+)?(throws\s+)?->"#),
        ("swift",      #"@(State|Binding|Environment|EnvironmentObject|Observable|Published|Model|Query|MainActor|escaping)\b"#),
        // Python — line-anchored structural patterns
        ("python",     #"^\s*def\s+\w+\s*\([^)]*\)\s*(->\s*[\w\[\],\s]+)?\s*:"#),
        ("python",     #"^\s*from\s+[\w.]+\s+import\s+"#),
        ("python",     #"^\s*if\s+__name__\s*==\s*[\"']__main__[\"']\s*:"#),
        ("python",     #"^\s*class\s+\w+\s*(\([^)]*\))?\s*:"#),
        // Rust
        ("rust",       #"\bimpl\s+\w+(\s+for\s+\w+)?\s*\{"#),
        ("rust",       #"^\s*use\s+\w+(::\w+)+\s*;"#),
        ("rust",       #"\btrait\s+\w+\s*\{"#),
        // Java
        ("java",       #"^\s*import\s+java\."#),
        ("java",       #"\bSystem\.out\.println\s*\("#),
        ("java",       #"@Override\b"#),
        // Kotlin
        ("kotlin",     #"^\s*data\s+class\s+\w+\s*\("#),
        ("kotlin",     #"^\s*sealed\s+(class|interface)\s+\w+"#),
        // C++
        ("cpp",        #"\bstd::\w+"#),
        ("cpp",        #"^\s*#include\s*<\w+>\s*$"#),
        ("cpp",        #"\bnamespace\s+\w+\s*\{"#),
        // C
        ("c",          #"^\s*#include\s*[<\"][\w./]+[>\"]"#),
        ("c",          #"\btypedef\s+struct\b"#),
        // Go
        ("go",         #"^\s*package\s+\w+\s*$"#),
        ("go",         #"\bfunc\s+(\(\s*\w+\s+\*?\w+\s*\)\s+)?\w+\s*\("#),
        ("go",         #"^\s*import\s+\("#),
        ("go",         #"\bfmt\.\w+\s*\("#),
        // TypeScript
        ("typescript", #"\binterface\s+\w+\s*\{"#),
        // JavaScript — arrow functions + module syntax
        ("javascript", #"\bconst\s+\w+\s*=\s*(\([^)]*\)\s*=>|async\s+\([^)]*\)\s*=>|function)"#),
        ("javascript", #"\b(console\.(log|error|warn)|require\s*\(|module\.exports|export\s+(default|const|function|class))"#),
        ("javascript", #"=>\s*\{"#),
        // PHP
        ("php",        #"<\?php"#),
        // Ruby — strong shapes only (def + body); bare `end` removed
        ("ruby",       #"^\s*def\s+\w+(\s*\([^)]*\))?\s*$"#),
        ("ruby",       #"^\s*require\s+['\"]"#),
        // C#
        ("csharp",     #"^\s*using\s+System(\.\w+)*\s*;"#),
        ("csharp",     #"\bnamespace\s+\w+(\.\w+)*\s*[\{;]"#),
        ("csharp",     #"\bConsole\.(WriteLine|Write|ReadLine)\s*\("#),
        // R
        ("r",          #"<-\s*function\s*\("#),
        ("r",          #"\bdata\.frame\s*\("#),
        ("r",          #"\bggplot\s*\("#),
        ("r",          #"%>%"#),
        // Dart / Flutter
        ("dart",       #"^\s*import\s+'package:flutter/"#),
        ("dart",       #"^\s*import\s+'dart:"#),
        ("dart",       #"\bWidget\s+build\s*\(\s*BuildContext\s+\w+\s*\)"#),
        ("dart",       #"\b(StatelessWidget|StatefulWidget|MaterialApp)\b"#),
        // Scala
        ("scala",      #"^\s*import\s+scala\."#),
        ("scala",      #"\b(case\s+class|sealed\s+trait)\s+\w+"#),
        // Lua — function-with-body, require with quoted string
        ("lua",        #"\bfunction\s+\w+(\.\w+|:\w+)?\s*\([^)]*\)"#),
        ("lua",        #"\brequire\s*\(?\s*['\"][\w.]+['\"]"#),
        // Perl
        ("perl",       #"^\s*use\s+strict\s*;"#),
        ("perl",       #"^\s*use\s+warnings\s*;"#),
        ("perl",       #"\$\w+\s*=~\s*[ms]?/"#),
        // Haskell
        ("haskell",    #"^\s*module\s+\w+(\.\w+)*\s+where"#),
        ("haskell",    #"^\s*import\s+(qualified\s+)?[A-Z]\w*(\.\w+)*"#),
        ("haskell",    #"::\s*(IO|Maybe|Either|\[a\])\b"#),
        // Elixir
        ("elixir",     #"^\s*defmodule\s+\w+(\.\w+)*\s+do\b"#),
        ("elixir",     #"^\s*def\s+\w+(\([^)]*\))?\s+do\b"#),
        ("elixir",     #"\b(IO\.puts|IO\.inspect)\s*\("#),
        // Erlang
        ("erlang",     #"^-module\s*\(\s*\w+\s*\)\s*\."#),
        ("erlang",     #"^-export\s*\(\s*\["#),
        ("erlang",     #"\bspawn\s*\(\s*fun\b"#),
        // Clojure
        ("clojure",    #"^\s*\(\s*ns\s+[\w.\-]+"#),
        ("clojure",    #"\(\s*defn?\s+\w+"#),
        ("clojure",    #"\(\s*println\s+"#),
        // F#
        ("fsharp",     #"\bprintfn\s+"#),
        ("fsharp",     #"^\s*open\s+System(\.\w+)*\s*$"#),
        // Zig — strong: @import("std"), pub fn, fn main()!void {
        ("zig",        #"\bconst\s+std\s*=\s*@import\s*\(\s*['\"]std['\"]\s*\)"#),
        ("zig",        #"\bpub\s+fn\s+\w+\s*\("#),
        ("zig",        #"\bfn\s+main\s*\(\s*\)\s+!?void\s*\{"#),
        ("zig",        #"@(import|cImport|TypeOf|ptrCast|sizeOf|panic)\s*\("#),
        // Mojo
        ("mojo",       #"^\s*fn\s+\w+\s*\([^)]*\)(\s*->\s*\w+)?\s*(raises\s+)?:"#),
        ("mojo",       #"^\s*struct\s+\w+\s*:"#),
        // Julia
        ("julia",      #"^\s*using\s+\w+(\s*,\s*\w+)*\s*$"#),
        ("julia",      #"::Vector\{|::Array\{|::Float64|::Int64"#),
        // OCaml
        ("ocaml",      #"^\s*let\s+rec\s+\w+\s+\w+(\s+\w+)*\s+="#),
        ("ocaml",      #"\bPrintf\.printf\s+"#),
        // V
        ("v",          #"^\s*fn\s+main\s*\(\s*\)\s*\{"#),
        // Nim
        ("nim",        #"^\s*proc\s+\w+\s*\([^)]*\)\s*:\s*\w+\s*=\s*$"#),
        ("nim",        #"^\s*import\s+(strutils|sequtils|tables|os|std/)"#),
        // Gleam
        ("gleam",      #"^\s*pub\s+fn\s+\w+\s*\("#),
        ("gleam",      #"^\s*import\s+gleam/"#),
        // Shell
        ("shell",      #"^#!/bin/(bash|sh|zsh|dash)"#),
        ("shell",      #"^#!/usr/bin/env\s+(bash|sh|zsh)"#),
        // SQL — tightened: require structural shape, not bare keyword
        ("sql",        #"\b(SELECT\s+[\w*,\s]+\s+FROM\s+\w+|INSERT\s+INTO\s+\w+|UPDATE\s+\w+\s+SET|DELETE\s+FROM\s+\w+|CREATE\s+TABLE\s+\w+|ALTER\s+TABLE\s+\w+|DROP\s+TABLE\s+\w+)\b"#),
        // HTML
        ("html",       #"<!DOCTYPE\s+html"#),
        ("html",       #"<html[\s>]"#),
        ("html",       #"</?(div|span|p|table|body|head|meta|script|style|h[1-6]|ul|ol|li|img|input|form|button|nav|header|footer|section|article|main|aside)[\s/>]"#),
        // CSS
        ("css",        #"^@(media|import|keyframes|font-face|supports|charset)\b"#),
        ("css",        #"\b(color|background-color|margin|padding|font-size|display|position|width|height|border)\s*:\s*[#\d\w'-]"#),
        // JSON (structural)
        ("json",       #"^\s*\{\s*\n[\s\S]*\"[^\"]+\"\s*:"#),
        ("json",       #"^\s*\[\s*\n[\s\S]*\{"#),
    ]

    /// Weak anchors — bare keywords that overlap with English. Need ≥ 2
    /// distinct weak anchors of the same language to fire (the multi-hit
    /// rule). A prose paragraph containing one such word does not tag.
    private static let weakAnchorPatterns: [(String, String)] = [
        // Swift control flow
        ("swift",      #"\bguard\s+let\s+\w+\s*="#),
        ("swift",      #"\bif\s+let\s+\w+\s*="#),
        // Python additional anchors (the line-anchored ones above are strong)
        ("python",     #"^\s*for\s+\w+(\s*,\s*\w+)*\s+in\s+\S.*:\s*$"#),
        ("python",     #"^\s*(if|elif|while|with|try|except|finally|else)\b[^{]*:\s*$"#),
        ("python",     #"^\s*import\s+[\w.]+(\s+as\s+\w+)?\s*$"#),
        ("python",     #"\bf['\"][^'\"]*\{[^}]+\}[^'\"]*['\"]"#),
        ("python",     #"\b(self|cls)\.\w+\s*[=(]"#),
        // Python lambda — tightened: require non-trivial body
        ("python",     #"\blambda\s+\w+\s*:\s*[\w(\[]"#),
        // Rust
        ("rust",       #"\bfn\s+\w+\s*(<[^>]+>)?\s*\([^)]*\)"#),
        ("rust",       #"\blet\s+mut\s+\w+"#),
        ("rust",       #"->\s+Result<"#),
        // Java
        ("java",       #"\b(public|private|protected)\s+(static\s+)?(final\s+)?(void|int|String|boolean|double|float|long|char|byte)\s+\w+\s*\("#),
        ("java",       #"\bpublic\s+class\s+\w+\s*(extends\s+\w+\s*)?(implements\s+[\w,\s]+\s*)?\{"#),
        // Kotlin
        ("kotlin",     #"\bfun\s+\w+\s*\([^)]*\)\s*:"#),
        // C++
        ("cpp",        #"\btemplate\s*<\s*(typename|class)\s+"#),
        // C — tightened: malloc/calloc/free with assignment context (free(time) in prose won't have that)
        ("c",          #"\b(int|void|char|float|double)\s+\w+\s*\([^)]*\)\s*\{"#),
        ("c",          #"\bprintf\s*\("#),
        ("c",          #"\b\w+\s*=\s*(malloc|calloc|realloc)\s*\("#),
        // Go
        ("go",         #":=\s*"#),
        // TypeScript — tightened: type X = with closing punctuation
        ("typescript", #"\btype\s+\w+\s*=\s*[\w<\[(].*[;|]"#),
        ("typescript", #"\(\s*[^)]*:\s*(string|number|boolean|void|any|unknown|never)\s*[,)]"#),
        // JavaScript
        ("javascript", #"\bfunction\s+\w+\s*\("#),
        // PHP
        ("php",        #"\$\w+\s*=\s*"#),
        // C#
        ("csharp",     #"\b(public|private|protected|internal)\s+(static\s+)?(async\s+)?(class|record|interface|struct|enum)\s+\w+"#),
        ("csharp",     #"\bvar\s+\w+\s*=\s*new\s+\w+"#),
        // R
        ("r",          #"^\s*library\s*\(\s*\w+\s*\)"#),
        // Dart
        ("dart",       #"\bvoid\s+main\s*\(\s*\)\s*\{"#),
        // Scala
        ("scala",      #"^\s*package\s+\w+(\.\w+)*\s*$"#),
        ("scala",      #"\bdef\s+\w+\s*\([^)]*\)\s*:\s*\w+\s*="#),
        ("scala",      #"\b(object|trait)\s+\w+"#),
        // Lua — bare local + multi-end
        ("lua",        #"\blocal\s+\w+\s*="#),
        ("lua",        #"\bend\s*$.*\n.*\bend\s*$"#),
        // Perl
        ("perl",       #"\bmy\s+\$\w+\s*="#),
        ("perl",       #"\bsub\s+\w+\s*\{"#),
        // Haskell
        ("haskell",    #"^\w+\s*::\s+"#),
        // Elixir
        ("elixir",     #"\|>"#),
        // F#
        ("fsharp",     #"^\s*module\s+[\w.]+\s*$"#),
        ("fsharp",     #"^\s*let\s+\w+\s+\w+(\s+\w+)*\s+="#),
        // Zig — tightened: defer must be followed by code-shape
        ("zig",        #"\b(comptime|errdefer|defer)\s+(\{|\w+\s*\(|\w+\.\w+)"#),
        // Mojo
        ("mojo",       #"^\s*from\s+\w+\s+import\s+.*\n.*\balias\s+"#),
        // Julia
        ("julia",      #"^\s*function\s+\w+\s*\([^)]*\)\s*$"#),
        ("julia",      #"^\s*end\s*$.*\n.*function\s+\w+"#),
        ("julia",      #"\bprintln\s*\("#),
        // OCaml
        ("ocaml",      #"^\s*open\s+[A-Z]\w*(\.\w+)*\s*$"#),
        ("ocaml",      #"\bmatch\s+.+\s+with\s*\n\s*\|"#),
        // V
        ("v",          #"^\s*module\s+\w+\s*$"#),
        ("v",          #"\bprintln\s*\(\s*['\"]"#),
        // Nim
        ("nim",        #"\becho\s+['\"]"#),
    ]


    /// Bundle IDs for code editors / IDEs. When clipboard content
    /// originates from one of these apps, the user is almost certainly
    /// copying source code — even if the snippet is too short or
    /// boilerplate-light to trigger anchor or keyword detection.
    public static let codeEditorBundleIDs: Set<String> = [
        "com.apple.dt.Xcode",
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92",       // Cursor
        "com.todesktop.230313mzl4w4u92.dev",
        "com.exafunction.windsurf",            // Windsurf
        "com.zed.Zed",
        "com.zed.Zed-Preview",
        "com.zed.Zed-Dev",
        "com.jetbrains.intellij",
        "com.jetbrains.intellij.ce",
        "com.jetbrains.pycharm",
        "com.jetbrains.pycharm.ce",
        "com.jetbrains.AppCode",
        "com.jetbrains.WebStorm",
        "com.jetbrains.CLion",
        "com.jetbrains.RubyMine",
        "com.jetbrains.goland",
        "com.jetbrains.rider",
        "com.jetbrains.datagrip",
        "com.jetbrains.AndroidStudio",
        "com.google.android.studio",
        "com.sublimetext.4",
        "com.sublimetext.3",
        "com.panic.Nova",
        "com.panic.Coda2",
        "com.barebones.bbedit",
        "abnerworks.Typora",
        "com.github.atom",
        "com.coderforlife.cppdroid",
    ]

    /// Best-effort default language when an IDE source is detected but
    /// no anchor / keyword matches. Keeps the row tagged as code with
    /// a sensible language hint instead of falling back to plain text.
    public static func defaultLanguageForIDE(_ bundleID: String) -> String? {
        switch bundleID {
        case "com.apple.dt.Xcode": return "swift"
        case "com.jetbrains.pycharm", "com.jetbrains.pycharm.ce": return "python"
        case "com.jetbrains.AppCode": return "objective-c"
        case "com.jetbrains.WebStorm": return "javascript"
        case "com.jetbrains.CLion": return "cpp"
        case "com.jetbrains.RubyMine": return "ruby"
        case "com.jetbrains.goland": return "go"
        case "com.jetbrains.rider": return "csharp"
        case "com.google.android.studio", "com.jetbrains.AndroidStudio": return "kotlin"
        default: return nil
        }
    }
}
