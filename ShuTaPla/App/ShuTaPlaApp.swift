//
//  ShuTaPlaApp.swift
//  ShuTaPla
//
//  @main entry point: the single main window, SwiftData container, the shared
//  AppState, and removal of the default "New Window" command. Cmd+, opens the
//  Settings scene.
//

import SwiftUI
import SwiftData
import AppKit

@main
struct ShuTaPlaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let modelContainer: ModelContainer?
    @State private var appState: AppState?
    @State private var thumbnailService = ThumbnailService()
    @State private var metadataService = MediaMetadataService()
    @State private var hdrCache = HDRCache()

    /// True when this process is the unit-test host. Xcode runs the app-hosted test target by
    /// launching the real app, so the store and window state below must be skipped: opening the
    /// on-disk store and resuming the window's player state would relaunch into fullscreen
    /// mid-run — creating a Space and shuffling the user's desktops — and freeze the shared main
    /// thread against the `@MainActor` suites. Each suite builds its own in-memory container, so
    /// nothing the tests exercise depends on this setup.
    nonisolated static let isTestHost = isRunningAsTestHost(ProcessInfo.processInfo.environment)

    nonisolated static func isRunningAsTestHost(_ environment: [String: String]) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil
    }

    init() {
        guard !Self.isTestHost else {
            self.modelContainer = nil
            self._appState = State(initialValue: nil)
            return
        }
        // Before the window exists, so it opens in the chosen appearance rather than flashing
        // the system one first.
        AppearanceMode.stored().apply()

        let schema = Schema(versionedSchema: SchemaV10.self)
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
        // `Window`, not `WindowGroup`: the app is single-window by design, and a group can vend a
        // second window — a Dock reopen racing the closed window's teardown produced one. Two windows
        // of this scene would host `RootView` twice over the one shared `AppState`, so every app-wide
        // alert presents in both (and presenting orders a hidden window front, which is how such a
        // duplicate surfaces). A `Window` scene is single-instance, so that cannot happen.
        //
        // Two invariants the rest of the app is written against, and this line is what makes them
        // true. Exactly one `RootView` instance exists, so `AppState` *is* window state — the mode,
        // the managed playlist, the selection, the frame and the one modal host are unambiguous, and
        // `HotkeyRouter`'s app-wide key monitor has a single window to route to. And that window and
        // its view tree are permanent: closing only hides them, with no teardown and no re-mount, so
        // window-scoped state (`FullscreenController`) outlives a close and view-lifecycle bridges
        // are silent across it.
        Window(AppConstants.appName, id: "main") {
            if let appState, let modelContainer {
                RootView()
                    .environment(appState)
                    .environment(appState.coordinator)
                    .environment(thumbnailService)
                    .environment(metadataService)
                    .environment(hdrCache)
                    .frame(minWidth: 800, minHeight: 600)
                    .modelContainer(modelContainer)
                    .onAppear {
                        appDelegate.appState = appState
                        appState.refreshCachePressureOnWindowOpen()
                    }
            } else {
                // Test host: no real store, no AppState, no window resume — just a bare window.
                Color.clear
            }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            if let appState {
                SettingsView()
                    .environment(appState)
                    .environment(thumbnailService)
            }
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
