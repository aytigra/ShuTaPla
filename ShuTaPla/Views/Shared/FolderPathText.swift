//
//  FolderPathText.swift
//  ShuTaPla
//
//  The secondary line that shows where a file is on disk, below its name.
//

import SwiftUI

/// The display form of a folder path: the home folder as `~`, iCloud Drive by name, no trailing slash.
nonisolated enum DisplayPath {

    /// The user's real home folder. In the sandbox `NSHomeDirectory()` returns the app container,
    /// so the path comes from the user database.
    static let home: String = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()

    /// The folder of the file at `relativePath` inside the playlist folder `folderPath`.
    static func folder(ofFile relativePath: String, in folderPath: String, home: String = home) -> String {
        let subfolders = relativePath.split(separator: "/").dropLast().joined(separator: "/")
        let folder = subfolders.isEmpty ? folderPath : (folderPath as NSString).appendingPathComponent(subfolders)
        return abbreviated(folder, home: home)
    }

    static func abbreviated(_ path: String, home: String = home) -> String {
        let path = trimmed(path)
        for (prefix, name) in [(home + "/Library/Mobile Documents/com~apple~CloudDocs", "iCloud Drive"), (home, "~")] {
            if path == prefix { return name }
            if path.hasPrefix(prefix + "/") { return name + path.dropFirst(prefix.count) }
        }
        return path
    }

    /// `path` without a trailing slash; the root stays `/`.
    private static func trimmed(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}

/// A folder path line, cut at the head so its end stays visible; the tooltip shows the whole text.
struct FolderPathText: View {
    let path: String

    init(file: PlaylistFile, in playlist: Playlist) {
        path = DisplayPath.folder(ofFile: file.relativePath, in: playlist.folderPath)
    }

    init(folderOf playlist: Playlist) {
        path = DisplayPath.abbreviated(playlist.folderPath)
    }

    var body: some View {
        Text(path)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.head)
            .help(path)
    }
}
