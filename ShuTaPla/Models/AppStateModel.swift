//
//  AppStateModel.swift
//  ShuTaPla
//
//  Persisted singleton holding the active-playlist IDs and window frame.
//  SwiftData has no built-in singleton; we use fetch-or-create (limit 1).
//

import Foundation
import SwiftData

@Model
final class AppStateModel {
    /// Video and image share the visual channel: at most one of these two is
    /// non-nil at a time.
    var activeVideoPlaylistId: UUID?
    var activeImagePlaylistId: UUID?

    /// Audio runs as an independent parallel channel.
    var activeAudioPlaylistId: UUID?

    /// Encoded `NSRect` of the window.
    var windowFrame: Data?

    init() {}

    /// Returns the single instance, creating and inserting it on first launch. If
    /// duplicates ever exist, the extras are pruned so the singleton stays unique
    /// and later reads are deterministic.
    static func fetchOrCreate(in context: ModelContext) -> AppStateModel {
        let all = (try? context.fetch(FetchDescriptor<AppStateModel>())) ?? []
        if let first = all.first {
            for extra in all.dropFirst() { context.delete(extra) }
            return first
        }
        let created = AppStateModel()
        context.insert(created)
        return created
    }
}
