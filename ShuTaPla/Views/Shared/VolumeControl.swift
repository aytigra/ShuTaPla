//
//  VolumeControl.swift
//  ShuTaPla
//
//  The per-playlist volume slider, worn by the audio transport's volume popover and the
//  player bar's video controls. Volume is a playlist preference, so the control addresses a
//  playlist rather than a channel: it reads and writes through the coordinator, which
//  persists the preference and forwards to that playlist's live engine if it has one.
//

import SwiftUI

struct VolumeControl: View {
    let playlist: Playlist
    /// The slider's width. Both hosts sit in a row that would otherwise stretch it, and each
    /// has its own room to give: the popover is sized by its content, the bar is not.
    let width: CGFloat

    @Environment(PlaybackCoordinator.self) private var coordinator

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "speaker.fill").font(.caption).foregroundStyle(.secondary)
            Slider(value: Binding(
                get: { coordinator.playbackVolume(for: playlist) },
                set: { coordinator.setVolume(playlist, to: $0) }
            ), in: 0...1)
            .frame(width: width)
        }
    }
}
