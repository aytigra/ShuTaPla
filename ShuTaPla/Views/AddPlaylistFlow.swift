//
//  AddPlaylistFlow.swift
//  ShuTaPla
//
//  The add-a-playlist flow after the folder is picked (`FolderPickFlow`, raised by
//  `AppState.folderPick = .addPlaylist`): the media-type choice for a Mixed folder, driven by
//  `AppState.pendingTypeChoice`, so every entry point owns only its trigger button. A failure is
//  an app-wide report (`ErrorNotice.addPlaylistFailed`).
//

import SwiftUI

struct AddPlaylistFlow: ViewModifier {
    @Environment(AppState.self) private var appState

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                "Choose a media type",
                isPresented: appState.isPresented(.typeChoice) { appState.pendingTypeChoice = nil },
                titleVisibility: .visible,
                presenting: appState.pendingTypeChoice
            ) { folder in
                ForEach(folder.typeChoices, id: \.self) { type in
                    Button(folder.choiceLabel(for: type)) {
                        appState.confirmPendingTypeChoice(type)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { folder in
                Text("“\(folder.name)” has a mix of media. Which type should this playlist be?")
            }
    }
}

extension View {
    /// Attaches the shared add-playlist flow's media-type choice after the folder pick, driven by
    /// `AppState`.
    func addPlaylistFlow() -> some View {
        modifier(AddPlaylistFlow())
    }
}
