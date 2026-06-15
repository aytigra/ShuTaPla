//
//  FileGalleryView.swift
//  ShuTaPla
//
//  The Manager center gallery: a `LazyVGrid` of thumbnail cells over the same
//  filtered files as the list view (`AppState.filteredFiles`), with identical
//  interactions — click / shift-click / cmd-click selection, double-click to
//  play, inline rename, and a per-cell context menu. Each cell loads its
//  thumbnail asynchronously and cancels the load when scrolled off-screen.
//

import SwiftUI
import AppKit

struct FileGalleryView: View {
    let playlist: Playlist
    let confirmDelete: ([PlaylistFile]) -> Void
    let reportError: (String) -> Void

    @Environment(AppState.self) private var appState

    @State private var anchor: UUID?
    @State private var renamingID: UUID?
    @State private var draftName = ""

    private static let minItemWidth: CGFloat = 150
    private static let gridSpacing: CGFloat = 12
    private let columns = [GridItem(.adaptive(minimum: minItemWidth, maximum: 220), spacing: gridSpacing)]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: Self.gridSpacing) {
                    ForEach(visibleFiles) { file in
                        cell(file)
                            .id(file.id)
                    }
                }
                .padding(Self.gridSpacing)
            }
            .overlay {
                if visibleFiles.isEmpty {
                    ContentUnavailableView("No Files", systemImage: "doc")
                }
            }
            // Track the live column count so keyboard arrows can navigate in 2D.
            .background {
                GeometryReader { geo in
                    Color.clear
                        .onAppear { appState.fileGridColumns = Self.columnCount(for: geo.size.width) }
                        .onChange(of: geo.size.width) { _, width in
                            appState.fileGridColumns = Self.columnCount(for: width)
                        }
                }
            }
            // Keep the keyboard-driven selection (single cell) visible as it moves.
            .onChange(of: appState.selectedFileIDs) { _, ids in
                guard ids.count == 1, let id = ids.first else { return }
                withAnimation { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    /// Mirrors `LazyVGrid`'s adaptive packing: as many `minItemWidth` columns as fit
    /// in the padded width, separated by `gridSpacing`.
    static func columnCount(for width: CGFloat) -> Int {
        let available = width - gridSpacing * 2          // outer padding
        guard available > 0 else { return 1 }
        return max(1, Int((available + gridSpacing) / (minItemWidth + gridSpacing)))
    }

    private func cell(_ file: PlaylistFile) -> some View {
        GalleryCell(
            file: file,
            playlist: playlist,
            isSelected: appState.selectedFileIDs.contains(file.id),
            isRenaming: renamingID == file.id,
            draftName: $draftName,
            onCommitRename: { commitRename(file) },
            onCancelRename: { renamingID = nil }
        )
        .onTapGesture(count: 2) { appState.beginPlayback(of: playlist, startingAt: file) }
        .onTapGesture { handleClick(file) }
        .contextMenu {
            Button("Rename") { beginRename(file) }
            Button("Show in Finder") { appState.revealInFinder(file) }
            Divider()
            Button("Delete", role: .destructive) {
                confirmDelete(FileSelection.deleteTargets(for: file, selection: appState.selectedFileIDs, visible: visibleFiles))
            }
        }
    }

    // MARK: - Data

    private var visibleFiles: [PlaylistFile] {
        appState.filteredFiles
    }

    // MARK: - Selection

    private func handleClick(_ file: PlaylistFile) {
        FileSelection.apply(
            click: file.id,
            modifiers: NSEvent.modifierFlags,
            in: visibleFiles,
            selection: &appState.selectedFileIDs,
            anchor: &anchor
        )
    }

    // MARK: - Rename

    private func beginRename(_ file: PlaylistFile) {
        draftName = file.fileName
        renamingID = file.id
    }

    private func commitRename(_ file: PlaylistFile) {
        let name = draftName
        renamingID = nil
        Task {
            if let error = await appState.renameFile(file, to: name) {
                reportError(error)
            }
        }
    }
}

/// One gallery tile: an async-loaded thumbnail with the filename (or an inline
/// rename field) beneath it, plus a selection highlight.
private struct GalleryCell: View {
    let file: PlaylistFile
    let playlist: Playlist
    let isSelected: Bool
    let isRenaming: Bool
    @Binding var draftName: String
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void

    @Environment(ThumbnailService.self) private var thumbnails
    @State private var image: NSImage?

    /// Longest-edge size in pixels: the cell's point size scaled for Retina.
    private let maxPixelSize = 440

    var body: some View {
        VStack(spacing: 6) {
            thumbnail
            caption
        }
        .padding(6)
        .background(isSelected ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .task(id: thumbnailKey) {
            // A previously generated thumbnail is served synchronously, so seen
            // cells don't flash a placeholder while scrolling; otherwise generate
            // it off the main actor.
            if let cached = thumbnails.cachedThumbnail(for: file, in: playlist, maxPixelSize: maxPixelSize) {
                image = cached
                return
            }
            image = await thumbnails.thumbnail(for: file, in: playlist, maxPixelSize: maxPixelSize)
        }
    }

    /// A uniform 4:3 tile: the rectangle fills the (equal) grid-column width, so
    /// every thumbnail is the same size regardless of the source's dimensions.
    /// The image fills and is center-cropped to the tile.
    private var thumbnail: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(.quaternary)
            .aspectRatio(4.0 / 3.0, contentMode: .fit)
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: playlist.mediaType == .video ? "film" : "photo")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
            }
    }

    @ViewBuilder
    private var caption: some View {
        if isRenaming {
            TextField("Name", text: $draftName)
                .textFieldStyle(.roundedBorder)
                .onSubmit(onCommitRename)
                .onExitCommand(perform: onCancelRename)
        } else {
            Text(file.fileName)
                .font(.caption)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
    }

    /// Reload when the file is replaced or renamed (path change).
    private var thumbnailKey: String { "\(file.id)|\(file.relativePath)" }
}
