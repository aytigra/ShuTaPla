//
//  PauseOverlay.swift
//  ShuTaPla
//
//  The suppression UI: an opaque full-screen cover shown while playback is
//  globally halted. It deliberately hides everything behind it and offers only
//  Unpause (lift suppression) and Stop (end playback, return to Manager).
//

import SwiftUI

struct PauseOverlay: View {
    let onUnpause: () -> Void
    let onStop: () -> Void

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black)
                .ignoresSafeArea()

            VStack(spacing: 28) {
                Image(systemName: "pause.circle.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(.white)

                HStack(spacing: 16) {
                    // `[space]` lifts suppression too, but `HotkeyRouter`'s app-wide
                    // monitor owns that key and routes it before any button shortcut
                    // fires, so the button carries no `.keyboardShortcut`.
                    Button(action: onUnpause) {
                        Label("Unpause", systemImage: "play.fill")
                            .frame(minWidth: 120)
                    }

                    Button(role: .destructive, action: onStop) {
                        Label("Stop", systemImage: "stop.fill")
                            .frame(minWidth: 120)
                    }
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
            }
        }
    }
}
