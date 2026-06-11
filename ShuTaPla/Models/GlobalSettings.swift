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

    /// Returns the single instance, creating and inserting it on first launch.
    static func fetchOrCreate(in context: ModelContext) -> GlobalSettings {
        var descriptor = FetchDescriptor<GlobalSettings>()
        descriptor.fetchLimit = 1
        if let existing = try? context.fetch(descriptor).first {
            return existing
        }
        let created = GlobalSettings()
        context.insert(created)
        return created
    }
}
