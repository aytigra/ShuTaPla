//
//  PlaylistCenterView.swift
//  ShuTaPla
//
//  The Manager center panel for the active scope: the cache banner, the filter strip, and the file
//  list. The playlist's name, Play, Reshuffle, and view-mode toggle live in the Manager toolbar.
//  The confirmations the list's interactions raise, and any failure they report, are presented
//  app-wide from `RootView`.
//

import SwiftUI
import SwiftData

struct PlaylistCenterView: View {
    @Environment(AppState.self) private var appState

    /// Set by the playlist scan when the on-disk thumbnail cache exceeds the caution threshold;
    /// drives the notice-strip cache-pressure banner.
    @AppStorage(AppConstants.thumbnailCacheOverLimitKey) private var cacheOverLimit = false

    var body: some View {
        Group {
            if let playlist = appState.managedPlaylist {
                center(playlist)
            } else {
                placeholder
            }
        }
    }

    // MARK: - Center

    /// The managed playlist's center: the filter strip over its file list. Visual playlists offer
    /// the gallery presentation; audio has no gallery, so it is always the list.
    @ViewBuilder
    private func center(_ playlist: Playlist) -> some View {
        VStack(spacing: 0) {
            if cacheOverLimit { cacheBanner }
            // Raised over the file list so the strip's saved-search dropdown and the expanded
            // fields' tag dropdowns overlay the rows instead of being clipped by them.
            FilterStrip(playlist: playlist)
                .zIndex(1)
            Divider()
            // One view type across every scope switch: audio has no gallery, so it is always
            // the list. Passing the presentation as `layout` (rather than picking between two
            // view types) keeps the browser's identity and scroll/selection state when the
            // scope changes between a gallery and a list playlist.
            FileCollectionView(
                playlist: playlist,
                layout: playlist.mediaType != .audio && playlist.preferences.viewMode == .gallery ? .gallery : .list,
                confirmDelete: { appState.requestManagerDelete($0) }
            )
        }
    }

    /// Shown when no playlist is managed in the current scope.
    private var placeholder: some View {
        ContentUnavailableView("Select a Playlist", systemImage: "rectangle.stack")
    }

    // MARK: - Cache banner

    /// Shown while the on-disk thumbnail cache is over the caution threshold; a click opens
    /// Settings, where the cache can be cleared.
    @ViewBuilder
    private var cacheBanner: some View {
        SettingsLink {
            Label("App cache > 1Gb!", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        Divider()
    }

}
