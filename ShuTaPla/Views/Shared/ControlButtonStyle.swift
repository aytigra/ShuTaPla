//
//  ControlButtonStyle.swift
//  ShuTaPla
//
//  The button style shared by the Player-mode control surfaces (the bottom playback
//  bar and the audio overlay). Padding gives each glyph a real hit target, and a
//  rounded fill appears on hover and deepens on press so the controls read as buttons
//  rather than bare icons.
//

import SwiftUI

struct ControlButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration)
    }

    private struct HoverBody: View {
        let configuration: ButtonStyle.Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    Color.primary.opacity(configuration.isPressed ? 0.22 : (hovering ? 0.13 : 0)),
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8))
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}
