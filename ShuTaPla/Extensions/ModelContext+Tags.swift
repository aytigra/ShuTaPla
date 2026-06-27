//
//  ModelContext+Tags.swift
//  ShuTaPla
//
//  Resolving filename tag tokens to the shared `Tag` records they map to. One place to
//  find-or-create a tag by its normalized name, so scan and rename both populate the
//  many-to-many relationship without ever inserting a duplicate.
//

import Foundation
import SwiftData

extension ModelContext {
    /// The shared `Tag` for `name`, inserted if none exists yet. Tags are deduped
    /// case-insensitively by their normalized (lowercased) name.
    func tag(named name: String) -> Tag {
        let normalized = name.lowercased()
        var descriptor = FetchDescriptor<Tag>(predicate: #Predicate { $0.normalizedName == normalized })
        descriptor.fetchLimit = 1
        if let existing = (try? fetch(descriptor))?.first { return existing }
        let tag = Tag(name: name, normalizedName: normalized)
        insert(tag)
        return tag
    }

    /// Resolves `names` to shared `Tag`s, de-duplicated case-insensitively (first casing wins).
    func tags(named names: [String]) -> [Tag] {
        TagParser.dedupe(names).map { tag(named: $0) }
    }
}
