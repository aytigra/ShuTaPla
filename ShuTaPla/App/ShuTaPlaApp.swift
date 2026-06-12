//
//  ShuTaPlaApp.swift
//  ShuTaPla
//
//  @main entry point: single WindowGroup, SwiftData container, the shared
//  AppState, and removal of the default "New Window" command to enforce a
//  single-window interface. Cmd+, opens the Settings scene.
//

import SwiftUI
import SwiftData

@main
struct ShuTaPlaApp: App {
    let modelContainer: ModelContainer
    @State private var appState: AppState
    @State private var thumbnailService = ThumbnailService()

    init() {
        let schema = Schema([
            Playlist.self,
            PlaylistFile.self,
            AppStateModel.self,
            GlobalSettings.self,
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        let container: ModelContainer
        do {
            container = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
        self.modelContainer = container
        self._appState = State(initialValue: AppState(modelContext: container.mainContext))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .environment(appState.coordinator)
                .environment(thumbnailService)
                .frame(minWidth: 800, minHeight: 600)
        }
        .modelContainer(modelContainer)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView()
        }
    }
}
