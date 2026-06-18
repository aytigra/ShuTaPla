//
//  WelcomeView.swift
//  ShuTaPla
//
//  First-run screen shown when no playlists exist. A prominent "Add Playlist"
//  button opens a folder picker; the chosen folder is scanned and turned into a
//  playlist, prompting for a media type when the folder is Mixed.
//

import SwiftUI
import UniformTypeIdentifiers

struct WelcomeView: View {
    @Environment(AppState.self) private var appState

    @State private var isImporting = false
    @State private var pending: PendingPlaylist?
    @State private var errorMessage: String?
    @State private var isWorking = false

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.hierarchical)

            VStack(spacing: 8) {
                Text("Welcome to ShuTaPla")
                    .font(.largeTitle.weight(.semibold))
                Text("Add a folder of videos, images, or audio to get started.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            Button {
                isImporting = true
            } label: {
                Label("Add Playlist", systemImage: "plus")
                    .font(.title3.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isWorking)

            if isWorking {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { Task { await add(url) } }
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
        .confirmationDialog(
            "Choose a media type",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            titleVisibility: .visible,
            presenting: pending
        ) { pending in
            ForEach(typeChoices(for: pending), id: \.self) { type in
                Button(label(for: type, in: pending)) {
                    appState.confirmPlaylist(pending, mediaType: type)
                    self.pending = nil
                }
            }
            Button("Cancel", role: .cancel) { self.pending = nil }
        } message: { pending in
            Text("“\(pending.name)” has a mix of media. Which type should this playlist be?")
        }
        .alert("Couldn't add playlist", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func add(_ url: URL) async {
        isWorking = true
        defer { isWorking = false }
        switch await appState.addPlaylist(from: url) {
        case .created:
            break  // AppState switches to manager mode
        case .needsTypeChoice(let p):
            pending = p
        case .empty:
            errorMessage = "“\(url.lastPathComponent)” has no videos, images, or audio files."
        case .failed(let message):
            errorMessage = message
        }
    }

    /// Media types present in a Mixed folder, ordered by frequency (most first).
    private func typeChoices(for pending: PendingPlaylist) -> [MediaType] {
        pending.scan.counts
            .filter { $0.value > 0 }
            .sorted { $0.value > $1.value }
            .map(\.key)
    }

    private func label(for type: MediaType, in pending: PendingPlaylist) -> String {
        let count = pending.scan.counts[type] ?? 0
        return "\(type.displayName) (\(count))"
    }
}
