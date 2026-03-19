import Foundation

public struct CodeDetector: Sendable {
    public struct Result: Sendable {
        public let isCode: Bool
        public let language: String?
        public let confidence: Double
    }

    public static func detect(in text: String) -> Result {
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
    private static func detectConfigFormat(_ text: String) -> String? {
        let lines = text.components(separatedBy: .newlines)
        let nonEmptyLines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard nonEmptyLines.count >= 3 else { return nil }

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
        if yamlKeyValue.count >= 3 && Double(yamlKeyValue.count) / Double(nonEmptyLines.count) > 0.5 {
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
            LanguagePattern(name: "shell", keywords: ["#!/bin", "echo ", "if [", "fi", "done", "export ", "chmod ", "grep ", "| "], minMatches: 3),
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
}
