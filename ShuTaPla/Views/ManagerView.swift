//
//  ManagerView.swift
//  ShuTaPla
//
//  Manager-mode shell. The three panes and their toolbar live in an AppKit
//  `NSSplitViewController` (`ManagerSplitScene`), whose custom `NSToolbar` places the
//  controls on the window's traffic-light line and aligns them to the panes with tracking
//  separators. This view is the SwiftUI seam: it reads the Manager environment, owns the
//  shared `ManagerChrome`, and hands both to the AppKit scene, which re-applies the
//  environment to each hosted pane.
//

import SwiftUI
import SwiftData

struct ManagerView: View {
    @Environment(AppState.self) private var appState
    @Environment(PlaybackCoordinator.self) private var coordinator
    @Environment(ThumbnailService.self) private var thumbnailService
    @Environment(MediaMetadataService.self) private var metadataService
    @Environment(\.modelContext) private var modelContext

    @State private var chrome = ManagerChrome()

    var body: some View {
        ManagerSplitScene(
            env: ManagerEnv(
                appState: appState,
                coordinator: coordinator,
                thumbnailService: thumbnailService,
                metadataService: metadataService,
                chrome: chrome,
                modelContainer: modelContext.container
            )
        )
        // Fill the window so the split view always spans its full width: otherwise SwiftUI sizes
        // the hosted controller to its fitting width and centers it, so a pane can't absorb a
        // divider drag and the inspector detaches from the edge as it collapses.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The split view reaches under the unified toolbar so its dividers line up with the
        // toolbar's tracking separators across the full window height.
        .ignoresSafeArea()
    }
}
