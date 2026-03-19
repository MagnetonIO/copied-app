import Foundation
import SwiftUI

public struct FuzzyMatch: Sendable {
    public let score: Int
    public let matchedRanges: [Range<String.Index>]
}

public struct FuzzyMatcher: Sendable {
    /// Performs fuzzy matching of `query` against `text`.
    /// Returns nil if the query doesn't match. Characters must appear in order.
    public static func match(query: String, in text: String) -> FuzzyMatch? {
        let queryLower = query.lowercased()
        let textLower = text.lowercased()

        // For 1-2 char queries, fall back to substring contains
        if queryLower.count <= 2 {
            guard let range = textLower.range(of: queryLower) else { return nil }
            return FuzzyMatch(score: 1, matchedRanges: [range])
        }

        var score = 0
        var matchedRanges: [Range<String.Index>] = []
        var consecutiveCount = 0
        var searchStart = textLower.startIndex

        var queryIndex = queryLower.startIndex
        var lastMatchIndex: String.Index?

        while queryIndex < queryLower.endIndex && searchStart < textLower.endIndex {
            let queryChar = queryLower[queryIndex]
            guard let foundIndex = textLower[searchStart...].firstIndex(of: queryChar) else {
                return nil // Character not found — no match
            }

            // Track the matched character range (in original text coordinates)
            let originalIndex = text.index(text.startIndex, offsetBy: textLower.distance(from: textLower.startIndex, to: foundIndex))
            let nextOriginal = text.index(after: originalIndex)
            matchedRanges.append(originalIndex..<nextOriginal)

            // First char bonus
            if queryIndex == queryLower.startIndex && foundIndex == textLower.startIndex {
                score += 15
            }

            // Consecutive match bonus
            if let lastMatch = lastMatchIndex, textLower.index(after: lastMatch) == foundIndex {
                consecutiveCount += 1
                score += 5 * consecutiveCount
            } else {
                consecutiveCount = 0
            }

            // Word boundary bonus
            if foundIndex == textLower.startIndex || isWordBoundary(textLower, at: foundIndex) {
                score += 10
            }

            // Gap penalty
            if let lastMatch = lastMatchIndex {
                let gap = textLower.distance(from: lastMatch, to: foundIndex) - 1
                score -= gap
            }

            lastMatchIndex = foundIndex
            searchStart = textLower.index(after: foundIndex)
            queryIndex = queryLower.index(after: queryIndex)
        }

        // All query chars must be consumed
        guard queryIndex == queryLower.endIndex else { return nil }

        return FuzzyMatch(score: score, matchedRanges: matchedRanges)
    }

    private static func isWordBoundary(_ text: String, at index: String.Index) -> Bool {
        guard index > text.startIndex else { return true }
        let prev = text[text.index(before: index)]
        let curr = text[index]
        // After separator
        if " ._-/\\".contains(prev) { return true }
        // camelCase transition
        if prev.isLowercase && curr.isUppercase { return true }
        return false
    }
}

// MARK: - Highlighted AttributedString

extension AttributedString {
    public static func highlighted(_ text: String, ranges: [Range<String.Index>], highlightColor: Color = .accentColor) -> AttributedString {
        var result = AttributedString(text)

        for range in ranges {
            guard let attrStart = AttributedString.Index(range.lowerBound, within: result),
                  let attrEnd = AttributedString.Index(range.upperBound, within: result) else { continue }
            result[attrStart..<attrEnd].foregroundColor = highlightColor
            result[attrStart..<attrEnd].font = .body.bold()
        }

        return result
    }
}
