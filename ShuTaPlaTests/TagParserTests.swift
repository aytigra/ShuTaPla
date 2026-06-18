//
//  TagParserTests.swift
//  ShuTaPlaTests
//
//  Task 2 — parsing, validation, and add/remove/rename filename rewriting.
//

import Testing
@testable import ShuTaPla

struct TagParserTests {

    // MARK: - Parsing

    @Test(arguments: [
        // Valid single-bracket filenames.
        ("sunset [beach sunny].jpg", TagParseResult.valid(["beach", "sunny"])),
        ("[bea].png", .valid(["bea"])),
        ("clip [tag1 tag_2 abc].mp4", .valid(["tag1", "tag_2", "abc"])),
        ("[ beach   sunny ].jpg", .valid(["beach", "sunny"])),       // extra whitespace
        ("clip [beach\tsunset].mp4", .valid(["beach", "sunset"])),   // tab separator
        ("clip [beach\u{00A0}sunset].mp4", .valid(["beach", "sunset"])), // non-breaking space
        ("photo [Beach].jpg", .valid(["Beach"])),                    // casing preserved

        // Untagged — no brackets.
        ("vacation.jpg", .untagged),
        ("no brackets here.mp4", .untagged),

        // Untagged — empty / whitespace-only group.
        ("photo [].jpg", .untagged),
        ("photo [   ].jpg", .untagged),

        // Untagged — stray unmatched bracket is ignored, not invalid.
        ("a [ b.mp4", .untagged),
        ("a ] b.mp4", .untagged),
        ("price ] drop.png", .untagged),

        // Invalid — multiple bracket groups.
        ("[a] [b].jpg", .invalid),
        ("first [beach] second [sand].mp4", .invalid),

        // Invalid — nested brackets.
        ("[a [b]].jpg", .invalid),
        ("x [outer [inner]] y.png", .invalid),

        // Invalid — a group with any non-conforming token.
        ("[beach ab].jpg", .invalid),     // "ab" too short
        ("[a b c].jpg", .invalid),        // all too short
        ("[beach sun-ny].jpg", .invalid), // disallowed character
        ("[be].jpg", .invalid),           // too short
    ])
    func parsing(_ fileName: String, _ expected: TagParseResult) {
        #expect(TagParser.parseTags(from: fileName) == expected)
    }

    // MARK: - Tag validation

    @Test(arguments: [
        ("beach", true),
        ("tag_1", true),
        ("abc", true),
        ("ab", false),          // too short
        ("a", false),
        ("be-ach", false),      // hyphen
        ("be ach", false),      // space
        ("béach", false),       // non-ASCII letter
    ])
    func validation(_ tag: String, _ valid: Bool) {
        #expect(TagParser.isValidTag(tag) == valid)
    }

    // MARK: - Add

    @Test func addToUntaggedAppendsBracket() {
        #expect(TagParser.addTag("beach", to: "sunset.jpg") == "sunset [beach].jpg")
    }

    @Test func addToTaggedExtendsBracket() {
        #expect(TagParser.addTag("sunny", to: "sunset [beach].jpg") == "sunset [beach sunny].jpg")
    }

    @Test func addReusesEmptyBracket() {
        #expect(TagParser.addTag("beach", to: "photo [].jpg") == "photo [beach].jpg")
    }

    @Test func addAlreadyPresentIsNoOp() {
        #expect(TagParser.addTag("beach", to: "sunset [beach].jpg") == "sunset [beach].jpg")
        // Case-insensitive.
        #expect(TagParser.addTag("BEACH", to: "sunset [beach].jpg") == "sunset [beach].jpg")
    }

    @Test func addInvalidTagIsRejected() {
        #expect(TagParser.addTag("ab", to: "sunset.jpg") == "sunset.jpg")
        #expect(TagParser.addTag("a-b", to: "sunset.jpg") == "sunset.jpg")
    }

    @Test func addToInvalidFileIsNoOp() {
        #expect(TagParser.addTag("beach", to: "[a] [b].jpg") == "[a] [b].jpg")
    }

    @Test func addToNameWithStrayOpenBracketIsNoOp() {
        // A stray "[" would make the appended bracket read as a second, nested group
        // (invalid); the original name is kept rather than corrupting the file's status.
        #expect(TagParser.addTag("abc", to: "a [ b.mp4") == "a [ b.mp4")
    }

    @Test func addToNameWithStrayCloseBracketAppendsNormally() {
        // A stray "]" is a harmless literal: the appended bracket is still the only
        // group, so the file becomes validly tagged rather than corrupted.
        #expect(TagParser.addTag("abc", to: "price ] drop.png") == "price ] drop [abc].png")
    }

    // MARK: - Remove

    @Test func removeOneOfSeveral() {
        #expect(TagParser.removeTag("beach", from: "sunset [beach sunny].jpg") == "sunset [sunny].jpg")
    }

    @Test func removeLastTagRemovesBrackets() {
        #expect(TagParser.removeTag("beach", from: "sunset [beach].jpg") == "sunset.jpg")
    }

    @Test func removeLastTagRemovesLeadingBracket() {
        #expect(TagParser.removeTag("beach", from: "[beach] sunset.jpg") == "sunset.jpg")
    }

    @Test func removeCaseInsensitive() {
        #expect(TagParser.removeTag("BEACH", from: "sunset [beach sunny].jpg") == "sunset [sunny].jpg")
    }

    @Test func removeAbsentTagIsNoOp() {
        #expect(TagParser.removeTag("sand", from: "sunset [beach].jpg") == "sunset [beach].jpg")
    }

    @Test func removeLastTagFromBracketOnlyNameUsesPlaceholder() {
        // The name is just its bracket group, so removing the only tag would leave an
        // empty (dot) name; a placeholder base is substituted instead.
        #expect(TagParser.removeTag("beach", from: "[beach].jpg") == "Untitled.jpg")
        #expect(TagParser.removeTag("beach", from: "[beach]") == "Untitled")
    }

    // MARK: - Rename

    @Test func renameTagReplaces() {
        #expect(TagParser.renameTag(from: "beach", to: "shore", in: "sunset [beach sunny].jpg") == "sunset [shore sunny].jpg")
    }

    @Test func renameCollapsesResultingDuplicate() {
        // [beach sand] rename sand -> beach collapses to [beach].
        #expect(TagParser.renameTag(from: "sand", to: "beach", in: "sunset [beach sand].jpg") == "sunset [beach].jpg")
    }

    @Test func renameInvalidNewTagIsNoOp() {
        #expect(TagParser.renameTag(from: "beach", to: "ab", in: "sunset [beach].jpg") == "sunset [beach].jpg")
    }

    @Test func renameAbsentOldTagIsNoOp() {
        #expect(TagParser.renameTag(from: "sand", to: "shore", in: "sunset [beach].jpg") == "sunset [beach].jpg")
    }
}
