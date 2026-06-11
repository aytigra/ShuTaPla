//
//  ShuTaPlaApp.swift
//  ShuTaPla
//
//  @main entry point: single WindowGroup, SwiftData container, and removal of
//  the default "New Window" command to enforce a single-window interface.
//

import SwiftUI
import SwiftData

@main
struct ShuTaPlaApp: App {
    let modelContainer: ModelContainer = {
        let schema = Schema([
            Playlist.self,
            PlaylistFile.self,
            AppStateModel.self,
            GlobalSettings.self,
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            // Placeholder until Task 4 introduces WelcomeView and mode switching.
            Text("ShuTaPla")
                .frame(minWidth: 800, minHeight: 600)
        }
        .modelContainer(modelContainer)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
