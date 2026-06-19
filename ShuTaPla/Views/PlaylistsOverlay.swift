//
//  PlaylistsOverlay.swift
//  ShuTaPla
//
//  The left-hover Playlists overlay in Player mode: read-only Video and Image sections
//  plus a collapsed Audio hint at the top. Selecting a playlist starts it immediately;
//  the Audio hint opens the extended audio overlay. Create/rename/delete/reorder live in
//  Manager mode only, so this is a pure selector.
//

import SwiftUI
import SwiftData

struct PlaylistsOverlay: View {
    @Environment(AppState.self) private var appState
    @Environment(OverlayManager.self) private var overlays
    @Query(sort: \Playlist.sortOrder) private var allPlaylists: [Playlist]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            audioHint
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section("Video", .video)
                    section("Image", .image)
                }
                .padding(.vertical, 14)
                .padding(.horizontal, 12)
            }
        }
        .frame(width: 280)
        .frame(maxHeight: .infinity)
        .playerOverlayPanel()
    }

    // MARK: - Sections

    @ViewBuilder
    private func section(_ title: String, _ mediaType: MediaType) -> some View {
        let playlists = allPlaylists.filter { $0.mediaType == mediaType }
        if !playlists.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(playlists) { playlist in
                    row(playlist)
                }
            }
        }
    }

    private func row(_ playlist: Playlist) -> some View {
        Button {
            appState.beginPlayback(of: playlist)
            overlays.hide(.playlistsSidebar)
        } label: {
            HStack {
                Text(playlist.name).lineLimit(1)
                Spacer()
                Text("\(playlist.files.count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                appState.coordinator.visualPlaylist === playlist ? Color.accentColor.opacity(AppConstants.selectionHighlightOpacity) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Audio hint

    private var audioHint: some View {
        Button {
            overlays.hide(.playlistsSidebar)
            overlays.expandAudioToExtended()
        } label: {
            Label {
                HStack {
                    Text("Audio")
                    Spacer()
                    let count = allPlaylists.filter { $0.mediaType == .audio }.count
                    if count > 0 {
                        Text("\(count)").monospacedDigit()
                    }
                    Image(systemName: "chevron.right").font(.caption2)
                }
            } icon: {
                Image(systemName: "music.note.list")
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
