//
//  AppState+Slots.swift
//  ShuTaPla
//
//  The slot references and the Manager's scope: restoring them from the persisted IDs at
//  launch, rebuilding the live channels, and the load/remember/switch-scope transitions that
//  move a playlist into the managed or remembered slots.
//

import Foundation
import SwiftData

extension AppState {

    // MARK: - Launch resume

    /// Restores the slot references and scope from the persisted IDs, then loads the
    /// persisted scope's remembered playlist into the managed slot.
    func resolveActivePlaylists() {
        lastManagedVideoPlaylist = appStateModel.lastManagedVideoPlaylistId.flatMap(playlist(withID:))
        lastManagedImagePlaylist = appStateModel.lastManagedImagePlaylistId.flatMap(playlist(withID:))
        audioChannelPlaylist = appStateModel.audioChannelPlaylistId.flatMap(playlist(withID:))
        managerScope = appStateModel.managerScopeRaw.flatMap(MediaType.init(rawValue:)) ?? .video
        managedPlaylist = rememberedPlaylist(for: managerScope)
    }

    private func playlist(withID id: UUID) -> Playlist? {
        var descriptor = FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    /// Rebuilds the live channels from each playlist's persisted state at launch — relaunch
    /// behaves like reopening the window, so Playing playlists resume and Paused stay paused.
    /// The audio channel rebuilds in whatever mode the window opens; a non-stopped visual
    /// playlist reopens Player mode (only if its channel actually came up).
    func reconstructPlayback() {
        if let audio = audioChannelPlaylist, audio.playbackState != .stopped {
            coordinator.reconstruct(audio)
        }
        if let visual = nonStoppedVisualPlaylist() {
            coordinator.reconstruct(visual)
            if coordinator.liveVisualPlaylist != nil { mode = .player }
        }
    }

    /// The single video or image playlist that was Playing or Paused at quit, if any. Starting a
    /// visual playlist stops the previous one, so at most one is ever non-stopped. `playbackState`
    /// is a `Codable` enum (not predicate-queryable), so the small playlist set is filtered in memory.
    private func nonStoppedVisualPlaylist() -> Playlist? {
        let all = (try? modelContext.fetch(FetchDescriptor<Playlist>())) ?? []
        return all.first { $0.mediaType != .audio && $0.playbackState != .stopped }
    }

    // MARK: - Slot references

    /// The remembered playlist for a media type — what switching to that scope loads into the
    /// managed slot. The visual memories (video / image) are independent of each other; audio's
    /// memory is the channel slot itself.
    func rememberedPlaylist(for mediaType: MediaType) -> Playlist? {
        switch mediaType {
        case .video: return lastManagedVideoPlaylist
        case .image: return lastManagedImagePlaylist
        case .audio: return audioChannelPlaylist
        }
    }

    /// Records `playlist` as its type's remembered playlist, persisting the choice. Touches neither
    /// the managed slot, the scope, nor playback.
    func remember(_ playlist: Playlist) {
        setRemembered(playlist, for: playlist.mediaType)
    }

    /// Points a media type's remembered slot at `playlist` (or clears it when `nil`), writing both
    /// the in-memory ref (for Observation) and its persisted id in one place.
    func setRemembered(_ playlist: Playlist?, for mediaType: MediaType) {
        switch mediaType {
        case .video:
            lastManagedVideoPlaylist = playlist
            appStateModel.lastManagedVideoPlaylistId = playlist?.id
        case .image:
            lastManagedImagePlaylist = playlist
            appStateModel.lastManagedImagePlaylistId = playlist?.id
        case .audio:
            audioChannelPlaylist = playlist
            appStateModel.audioChannelPlaylistId = playlist?.id
        }
    }

    /// Loads `playlist` into the managed slot: records it and sets the scope to its type, so the
    /// whole Manager binds to it. The one load step that makes a playlist managed; playback is a
    /// separate concern handled by the callers that start it.
    func setManaged(_ playlist: Playlist) {
        setDuplicateSearch(false)   // find-duplicates is scoped to one managed playlist; a switch exits it
        remember(playlist)
        managedPlaylist = playlist
        managerScope = playlist.mediaType
        appStateModel.managerScopeRaw = managerScope.rawValue
    }

    /// The browse gesture: switches the sidebar to `scope` and pre-loads that scope's remembered
    /// playlist into the managed slot (possibly `nil` → the placeholder). Selection belongs to the
    /// managed playlist, so it clears and re-seeds on the new playlist's resume file.
    func switchScope(to scope: MediaType) {
        guard scope != managerScope else { return }
        setDuplicateSearch(false)   // the mode is scoped to one managed playlist; a scope switch exits it
        managerScope = scope
        appStateModel.managerScopeRaw = scope.rawValue
        managedPlaylist = rememberedPlaylist(for: scope)
        reseedManagerSelection()
    }
}
