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
import AppKit

@main
struct ShuTaPlaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    let modelContainer: ModelContainer
    @State private var appState: AppState
    @State private var thumbnailService = ThumbnailService()
    @State private var metadataService = MediaMetadataService()

    init() {
        let schema = Schema(versionedSchema: SchemaV5.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        let container: ModelContainer
        do {
            container = try ModelContainer(
                for: schema,
                migrationPlan: AppMigrationPlan.self,
                configurations: [configuration]
            )
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
                .environment(metadataService)
                .frame(minWidth: 800, minHeight: 600)
                .onAppear { appDelegate.appState = appState }
        }
        .modelContainer(modelContainer)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView()
                .environment(appState)
        }
    }
}

/// Owns the app-level lifecycle hooks SwiftUI's `App` can't express: keeping the app
/// running when the window closes, lifting the close-time suppression on a Dock reopen, and
/// a final position persist on quit. The window-close halt itself is observed in-window by
/// `WindowCloseBridge` (so the Settings window doesn't trigger it).
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Wired once the main window appears. The lifecycle callbacks below all run after that,
    /// so it is set by the time they fire.
    var appState: AppState?

    /// Closing the window hides it but keeps the app running (Dock reopen restores it).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Dock-icon click with no visible window: lift the close-time suppression so Playing
    /// playlists continue, and let AppKit re-show the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { appState?.windowWillReopen() }
        return true
    }

    /// Quit: a final write of both channels' live positions before teardown.
    func applicationWillTerminate(_ notification: Notification) {
        appState?.applicationWillTerminate()
    }
}
