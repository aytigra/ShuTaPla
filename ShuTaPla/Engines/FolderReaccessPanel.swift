//
//  FolderReaccessPanel.swift
//  ShuTaPla
//
//  The production `FolderReaccessPrompting`: an `NSOpenPanel` asking the user to point at a
//  playlist's folder to re-grant security-scoped access after its bookmark goes stale. The sole
//  AppKit dependency of the folder-access machinery, kept out of `ScopedFolderAccess`.
//

import AppKit

@MainActor
struct FolderReaccessPanel: FolderReaccessPrompting {
    func requestAccess(to playlist: Playlist) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Grant Access"
        panel.message = "Locate “\(playlist.name)” to let ShuTaPla modify its files."
        panel.directoryURL = URL(fileURLWithPath: playlist.folderPath)
        return panel.runModal() == .OK ? panel.url : nil
    }
}
