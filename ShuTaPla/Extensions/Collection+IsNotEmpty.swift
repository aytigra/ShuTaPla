//
//  Collection+IsNotEmpty.swift
//  ShuTaPla
//
//  The one home for the "has any element" negation, so call sites read `x.isNotEmpty` rather than
//  the easy-to-misread `!x.isEmpty`. Covers every Collection — String, Array, Set, Dictionary.
//

extension Collection {
    /// Whether the collection has any element — the positive reading of `!isEmpty`.
    nonisolated var isNotEmpty: Bool { !isEmpty }
}
