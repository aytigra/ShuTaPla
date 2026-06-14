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
    @State private var hotkeyRouter = HotkeyRouter()
    @State private var overlayManager = OverlayManager()

    var body: some View {
        Group {
            switch appState.mode {
            case .welcome:
                WelcomeView()
            case .manager:
                ManagerView()
            case .player:
                PlayerView()
            }
        }
        .environment(overlayManager)
        .onAppear {
            hotkeyRouter.appState = appState
            hotkeyRouter.overlayContext = overlayManager
            hotkeyRouter.startMonitoring()
        }
        .onDisappear { hotkeyRouter.stopMonitoring() }
    }
}
