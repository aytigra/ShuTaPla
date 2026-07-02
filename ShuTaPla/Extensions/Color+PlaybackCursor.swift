//
//  Color+PlaybackCursor.swift
//  ShuTaPla
//
//  The purple border marking the Manager's playback cursor (`Playlist.currentFileID`) —
//  the file playback sits on or would resume from. Distinct from the accent used for the
//  multi-select highlight so "where playback sits" and "what's selected" never blend.
//

import SwiftUI

extension Color {
    static let playbackCursor = Color(.sRGB, red: 0.64, green: 0.32, blue: 0.93, opacity: 1)
}
