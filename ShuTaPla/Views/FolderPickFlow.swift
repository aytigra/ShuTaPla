//
//  FolderPickFlow.swift
//  ShuTaPla
//
//  The one folder chooser every pick shares — adding a playlist, moving files — driven by
//  `AppState.folderPick`. Its purpose decides what the chosen folder is for, where the panel
//  starts, and what its confirm button says.
//

import SwiftUI
import UniformTypeIdentifiers

struct FolderPickFlow: ViewModifier {
    @Environment(AppState.self) private var appState

    func body(content: Content) -> some View {
        // Captured here rather than read back on completion: the panel's dismissal clears
        // `folderPick` through the binding, possibly before the completion runs.
        let pick = appState.windowModals.shown?.folderPick
        let isMove = if case .move = pick { true } else { false }
        content
            .fileImporter(
                isPresented: appState.isPresented(.folderPick) { appState.folderPick = nil },
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                if let pick { appState.completeFolderPick(pick, with: result) }
            }
            .fileDialogDefaultDirectory(isMove ? appState.lastMoveDestination : nil)
            .fileDialogConfirmationLabel(isMove ? Text("Move") : nil)
    }
}

extension View {
    /// Attaches the shared folder chooser, driven by `AppState.folderPick`.
    func folderPickFlow() -> some View {
        modifier(FolderPickFlow())
    }
}
