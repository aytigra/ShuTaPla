//
//  TagParser.swift
//  ShuTaPla
//
//  Pure functions for reading and rewriting the tag bracket in a filename.
//  No state, no dependencies — easily unit-tested. Operates on the filename
//  base (extension excluded); the on-disk casing is preserved while matching
//  is case-insensitive.
//

import Foundation

/// Result of parsing the tag bracket in a filename base.
nonisolated enum TagParseResult: Sendable, Equatable {
    case valid([String])
    case untagged
    case invalid
}

nonisolated enum TagParser {

    /// Minimum length for a valid tag token.
    static let minTagLength = 3

    // MARK: - Validation

    /// A tag is letters, digits, or underscore (ASCII), at least `minTagLength`.
    static func isValidTag(_ tag: String) -> Bool {
        guard tag.count >= minTagLength else { return false }
        return tag.allSatisfy { ch in
            ch.isASCII && (ch.isLetter || ch.isNumber || ch == "_")
        }
    }

    // MARK: - Parsing

    static func parseTags(from fileName: String) -> TagParseResult {
        let base = (fileName as NSString).deletingPathExtension
        let scan = scanBracket(in: base)
        if scan.invalid { return .invalid }
        guard let content = scan.content else { return .untagged }

        if content.trimmingCharacters(in: .whitespaces).isEmpty {
            return .untagged  // `[]` or whitespace-only group, cleaned up on next edit
        }

        let tokens = content.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        return tokens.allSatisfy(isValidTag) ? .valid(tokens) : .invalid
    }

    // MARK: - Editing

    /// Adds a tag. No-op if the tag is invalid, the file is invalid-tagged, or
    /// the tag is already present (case-insensitively).
    static func addTag(_ tag: String, to fileName: String) -> String {
        guard isValidTag(tag) else { return fileName }
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension

        switch parseTags(from: fileName) {
        case .invalid:
            return fileName
        case .untagged:
            return assemble(base: writeTags([tag], inBase: base), ext: ext)
        case .valid(let tags):
            if tags.contains(where: { sameTag($0, tag) }) { return fileName }
            return assemble(base: writeTags(tags + [tag], inBase: base), ext: ext)
        }
    }

    /// Removes a tag. Removes the empty brackets when the last tag goes.
    /// No-op if the file isn't validly tagged or the tag isn't present.
    static func removeTag(_ tag: String, from fileName: String) -> String {
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        guard case .valid(let tags) = parseTags(from: fileName) else { return fileName }

        let remaining = tags.filter { !sameTag($0, tag) }
        if remaining.count == tags.count { return fileName }  // not present
        return assemble(base: writeTags(remaining, inBase: base), ext: ext)
    }

    /// Renames a tag, collapsing any resulting within-file duplicate to one
    /// instance. No-op if the new tag is invalid, the file isn't validly
    /// tagged, or the old tag isn't present.
    static func renameTag(from oldTag: String, to newTag: String, in fileName: String) -> String {
        guard isValidTag(newTag) else { return fileName }
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        guard case .valid(let tags) = parseTags(from: fileName) else { return fileName }
        guard tags.contains(where: { sameTag($0, oldTag) }) else { return fileName }

        let mapped = tags.map { sameTag($0, oldTag) ? newTag : $0 }
        return assemble(base: writeTags(dedupe(mapped), inBase: base), ext: ext)
    }

    // MARK: - Bracket scanning

    private struct BracketScan {
        /// Nesting, or more than one balanced pair.
        var invalid = false
        /// Full range of the single pair (including brackets), if exactly one.
        var range: Range<String.Index>?
        /// Inner content of the single pair, if exactly one.
        var content: String?
    }

    /// Scans the base left to right tracking nesting depth.
    /// - A `[` while already inside a pair → invalid (nesting).
    /// - More than one balanced pair → invalid.
    /// - An unmatched `[` or `]` that never forms a pair is ignored (literal).
    private static func scanBracket(in base: String) -> BracketScan {
        var depth = 0
        var pairCount = 0
        var openIndex: String.Index?
        var result = BracketScan()

        var i = base.startIndex
        while i < base.endIndex {
            let ch = base[i]
            if ch == "[" {
                if depth >= 1 { return BracketScan(invalid: true, range: nil, content: nil) }
                depth = 1
                openIndex = i
            } else if ch == "]", depth == 1 {
                depth = 0
                pairCount += 1
                if pairCount > 1 { return BracketScan(invalid: true, range: nil, content: nil) }
                let open = openIndex!
                let closeAfter = base.index(after: i)
                result.range = open..<closeAfter
                result.content = String(base[base.index(after: open)..<i])
            }
            i = base.index(after: i)
        }
        return result
    }

    // MARK: - Bracket rewriting

    /// Returns a new base with the tag bracket set to `tags`. An empty `tags`
    /// removes the bracket (and an adjacent separating space). Reuses an
    /// existing bracket position; otherwise appends.
    private static func writeTags(_ tags: [String], inBase base: String) -> String {
        let scan = scanBracket(in: base)

        if tags.isEmpty {
            guard let range = scan.range else { return base }
            return removingBracket(range: range, in: base)
        }

        let bracket = "[" + tags.joined(separator: " ") + "]"
        if let range = scan.range {
            var newBase = base
            newBase.replaceSubrange(range, with: bracket)
            return newBase
        }
        if base.isEmpty { return bracket }
        return base.hasSuffix(" ") ? base + bracket : base + " " + bracket
    }

    /// Removes the bracket and one adjacent separating space, then trims edges.
    private static func removingBracket(range: Range<String.Index>, in base: String) -> String {
        var lower = range.lowerBound
        var upper = range.upperBound

        if lower > base.startIndex, base[base.index(before: lower)] == " " {
            lower = base.index(before: lower)
        } else if upper < base.endIndex, base[upper] == " " {
            upper = base.index(after: upper)
        }

        var newBase = base
        newBase.removeSubrange(lower..<upper)
        return newBase.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Helpers

    private static func sameTag(_ a: String, _ b: String) -> Bool {
        a.caseInsensitiveCompare(b) == .orderedSame
    }

    /// Case-insensitive de-duplication preserving order and first-seen casing.
    private static func dedupe(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for tag in tags where seen.insert(tag.lowercased()).inserted {
            result.append(tag)
        }
        return result
    }

    private static func assemble(base: String, ext: String) -> String {
        ext.isEmpty ? base : base + "." + ext
    }
}
