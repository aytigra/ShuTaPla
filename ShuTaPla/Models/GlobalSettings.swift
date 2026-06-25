//
//  GlobalSettings.swift
//  ShuTaPla
//
//  Persisted singleton holding global defaults that per-playlist preferences
//  fall back to. Fetch-or-create, same as `AppStateModel`.
//

import Foundation
import SwiftData

@Model
final class GlobalSettings {
    var defaultSlideshowInterval: TimeInterval = 10.0
    var defaultFilePositionPersistence: Bool = false
    var defaultImageFitMode: ImageFitMode = ImageFitMode.fit

    init() {}

    /// Returns the single instance, creating and inserting it on first launch. If
    /// duplicates ever exist, the extras are pruned so the singleton stays unique
    /// and later reads are deterministic.
    static func fetchOrCreate(in context: ModelContext) -> GlobalSettings {
        do {
            let all = try context.fetch(FetchDescriptor<GlobalSettings>())
            if let first = all.first {
                for extra in all.dropFirst() { context.delete(extra) }
                return first
            }
        } catch {
            // A transient fetch failure must not be mistaken for "none exists": inserting
            // then would write a second singleton that a later launch prunes, losing the
            // stored defaults. Hand back a detached instance instead so this session
            // degrades without persisting a duplicate.
            return GlobalSettings()
        }
        let created = GlobalSettings()
        context.insert(created)
        return created
    }
}
