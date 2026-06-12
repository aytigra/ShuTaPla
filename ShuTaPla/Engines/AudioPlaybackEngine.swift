//
//  AudioPlaybackEngine.swift
//  ShuTaPla
//
//  The audio channel. An `MPVPlaybackEngine` whose client is configured with
//  `--vo=null` (no video output) so it only decodes audio. It runs independently
//  of the visual channel: on macOS two mpv instances mix into CoreAudio at once,
//  each contributing at its own `volume`.
//

import Foundation

@MainActor
final class AudioPlaybackEngine: MPVPlaybackEngine {

    init() throws {
        try super.init(configuration: .audio)
    }
}
