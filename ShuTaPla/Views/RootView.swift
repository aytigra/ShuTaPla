//
//  RootView.swift
//  ShuTaPla
//
//  Top-level view that switches the window between Welcome, Manager, and Player
//  based on `AppState.mode`.
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
            PlayerView()
        }
    }
}
