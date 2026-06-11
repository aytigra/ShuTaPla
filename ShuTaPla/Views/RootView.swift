//
//  RootView.swift
//  ShuTaPla
//
//  Top-level view that switches the window between Welcome, Manager, and Player
//  based on `AppState.mode`. Player is a placeholder until its task lands.
//

import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        switch appState.mode {
        case .welcome:
            WelcomeView()
        case .manager:
            ManagerView()
        case .player:
            PlayerPlaceholderView()
        }
    }
}

/// Stand-in for the Player UI (Task 11+). Until real playback and hotkeys land,
/// a Back button returns to Manager mode.
private struct PlayerPlaceholderView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Color.black
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
            .overlay(alignment: .topLeading) {
                Button {
                    appState.mode = .manager
                } label: {
                    Label("Back to Manager", systemImage: "chevron.left")
                }
                .padding()
            }
    }
}
