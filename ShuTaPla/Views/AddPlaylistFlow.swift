//
//  AddPlaylistFlow.swift
//  ShuTaPla
//
//  The add-a-playlist flow shared by the Welcome screen and the sidebar's plus
//  button: a folder picker, then a media-type choice for a Mixed folder or an error
//  alert. All of it is driven by observable state on `AppState` (raise the flow by
//  setting `AppState.isImportingPlaylist`), so the two entry points attach the same
//  modifier and own only their trigger button.
//

import SwiftUI
import UniformTypeIdentifiers

struct AddPlaylistFlow: ViewModifier {
    @Environment(AppState.self) private var appState

    func body(content: Content) -> some View {
        @Bindable var appState = appState
        content
            .fileImporter(
                isPresented: $appState.isImportingPlaylist,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first { Task { await appState.importPlaylist(from: url) } }
                case .failure(let error):
                    appState.addPlaylistError = error.localizedDescription
                }
            }
            .confirmationDialog(
                "Choose a media type",
                isPresented: Binding(
                    get: { appState.pendingTypeChoice != nil },
                    set: { if !$0 { appState.pendingTypeChoice = nil } }
                ),
                titleVisibility: .visible,
                presenting: appState.pendingTypeChoice
            ) { pending in
                ForEach(pending.typeChoices, id: \.self) { type in
                    Button(pending.choiceLabel(for: type)) {
                        appState.confirmPendingTypeChoice(type)
                    }
                }
                Button("Cancel", role: .cancel) { appState.pendingTypeChoice = nil }
            } message: { pending in
                Text("“\(pending.name)” has a mix of media. Which type should this playlist be?")
            }
            .alert(
                "Couldn't add playlist",
                isPresented: Binding(
                    get: { appState.addPlaylistError != nil },
                    set: { if !$0 { appState.addPlaylistError = nil } }
                )
            ) {
                Button("OK", role: .cancel) { appState.addPlaylistError = nil }
            } message: {
                Text(appState.addPlaylistError ?? "")
            }
    }
}

extension View {
    /// Attaches the shared add-playlist flow (folder picker → scan → media-type
    /// choice or error), driven by `AppState`. Raise it by setting
    /// `AppState.isImportingPlaylist`.
    func addPlaylistFlow() -> some View {
        modifier(AddPlaylistFlow())
    }
}
