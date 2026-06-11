//
//  RootView.swift
//  ShuTaPla
//
//  Top-level view that switches the window between Welcome, Manager, and Player
//  based on `AppState.mode`. Manager and Player are placeholders until their
//  tasks land.
//

import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        switch appState.mode {
        case .welcome:
            WelcomeView()
        case .manager:
            ManagerPlaceholderView()
        case .player:
            PlayerPlaceholderView()
        }
    }
}

/// Stand-in for the Manager UI (Task 5+).
private struct ManagerPlaceholderView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "rectangle.3.group")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Manager")
                .font(.title2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Stand-in for the Player UI (Task 11+).
private struct PlayerPlaceholderView: View {
    var body: some View {
        Color.black
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
    }
}
