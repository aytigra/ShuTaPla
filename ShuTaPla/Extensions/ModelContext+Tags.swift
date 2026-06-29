//
//  ModelContext+Tags.swift
//  ShuTaPla
//
//  Resolving filename tag tokens to the shared `Tag` records they map to. One place to
//  find-or-create a tag by its normalized name, so scan and rename both populate the
//  many-to-many relationship without ever inserting a duplicate.
//
//  `nonisolated`: the background `PlaylistScanActor` resolves tags on its own context off the
//  main actor, and the main-actor rename path resolves them on the main context. The work is
//  pure store I/O on whichever context is passed, with no main-actor state, so it runs wherever
//  its caller does.
//

import Foundation
import SwiftData

nonisolated extension ModelContext {
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

    /// Every existing `Tag` keyed by its normalized name — the seed a bulk caller hands to
    /// `tags(named:cache:)` so a whole playlist's tags resolve from one fetch.
    func tagsByNormalizedName() -> [String: Tag] {
        let all = (try? fetch(FetchDescriptor<Tag>())) ?? []
        return Dictionary(all.map { ($0.normalizedName, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Resolves `names` to shared `Tag`s against an in-memory `cache` keyed by normalized name,
    /// inserting (and caching) any the cache doesn't hold yet. A caller resolving many files'
    /// tags primes the cache once with `tagsByNormalizedName()` and find-or-creates in memory,
    /// rather than a per-name store fetch. Tags inserted here join the cache, so the same name
    /// across two files yields one shared row.
    func tags(named names: [String], cache: inout [String: Tag]) -> [Tag] {
        TagParser.dedupe(names).map { name in
            let normalized = name.lowercased()
            if let existing = cache[normalized] { return existing }
            let tag = Tag(name: name, normalizedName: normalized)
            insert(tag)
            cache[normalized] = tag
            return tag
        }
    }
}
