//
//  SettingsView.swift
//  ShuTaPla
//
//  Global settings, opened with Cmd+, via the `Settings` scene. A stub for now;
//  Task 16 fills in the global defaults (slideshow interval, file-position
//  persistence, image fit mode).
//

import SwiftUI

struct SettingsView: View {
    var body: some View {
        Form {
            Text("Settings will appear here.")
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 200)
    }
}
