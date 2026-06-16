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
    var defaultSlideshowInterval: TimeInterval = 5.0
    var defaultFilePositionPersistence: Bool = false
    var defaultImageFitMode: ImageFitMode = ImageFitMode.fit

    init() {}

    /// Returns the single instance, creating and inserting it on first launch. If
    /// duplicates ever exist, the extras are pruned so the singleton stays unique
    /// and later reads are deterministic.
    static func fetchOrCreate(in context: ModelContext) -> GlobalSettings {
        let all = (try? context.fetch(FetchDescriptor<GlobalSettings>())) ?? []
        if let first = all.first {
            for extra in all.dropFirst() { context.delete(extra) }
            return first
        }
        let created = GlobalSettings()
        context.insert(created)
        return created
    }
}
