//
//  FileCollectionView.swift
//  ShuTaPla
//
//  The Manager center file browser, shared by the list and gallery presentations.
//  Both show the same filtered files (`AppState.filteredFiles`) with the same
//  interactions — click / shift-click / cmd-click selection, double-click to play,
//  inline rename, a per-item context menu, and keyboard-selection auto-scroll —
//  differing only in layout (a divided `LazyVStack` of rows vs a `LazyVGrid` of
//  thumbnail cells) and the cell view. The selection, rename, and scroll
//  bookkeeping lives here once; `FileListView`/`FileGalleryView` supply the layout
//  and cell.
//

import SwiftUI
import AppKit

/// Which presentation the shared browser draws.
nonisolated enum FileCollectionLayout {
    case list
    case gallery

    /// Gallery grid metrics, shared by the `LazyVGrid` columns and the keyboard
    /// navigator's column-count derivation.
    static let galleryMinItemWidth: CGFloat = 150
    static let gallerySpacing: CGFloat = 12

    /// Mirrors `LazyVGrid`'s adaptive packing: as many `galleryMinItemWidth` columns
    /// as fit in the padded width, separated by `gallerySpacing`.
    static func galleryColumnCount(for width: CGFloat) -> Int {
        let available = width - gallerySpacing * 2          // outer padding
        guard available > 0 else { return 1 }
        return max(1, Int((available + gallerySpacing) / (galleryMinItemWidth + gallerySpacing)))
    }
}

/// The per-file inputs a cell needs: its selection / rename / stripping state and
/// the rename field's draft binding and commit/cancel handlers.
struct FileCellConfiguration {
    let file: PlaylistFile
    let playlist: Playlist
    let isSelected: Bool
    let isRenaming: Bool
    let isStripping: Bool
    let draftName: Binding<String>
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void
}

struct FileCollectionView<Cell: View>: View {
    let playlist: Playlist
    let layout: FileCollectionLayout
    let confirmDelete: ([PlaylistFile]) -> Void
    let reportError: (String) -> Void
    @ViewBuilder let cell: (FileCellConfiguration) -> Cell

    @Environment(AppState.self) private var appState

    @State private var anchor: UUID?
    @State private var renamingID: UUID?
    @State private var draftName = ""
    // A mouse click already targets a visible item, so the auto-scroll that keeps the
    // keyboard selection centered would only jar the view. Set when a click changes
    // the selection, consumed by the next selection-change scroll.
    @State private var skipSelectionScroll = false

    private var columns: [GridItem] {
        [GridItem(
            .adaptive(minimum: FileCollectionLayout.galleryMinItemWidth, maximum: 220),
            spacing: FileCollectionLayout.gallerySpacing
        )]
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                switch layout {
                case .list:
                    LazyVStack(spacing: 0) {
                        ForEach(visibleFiles) { file in
                            item(file)
                            Divider()
                        }
                    }
                case .gallery:
                    LazyVGrid(columns: columns, spacing: FileCollectionLayout.gallerySpacing) {
                        ForEach(visibleFiles) { file in
                            item(file)
                                // Pin each tile to the top of its grid row so cells with
                                // one- and two-line captions line up at the thumbnail
                                // rather than centering against each other.
                                .frame(maxHeight: .infinity, alignment: .top)
                        }
                    }
                    .padding(FileCollectionLayout.gallerySpacing)
                }
            }
            .overlay {
                if visibleFiles.isEmpty {
                    ContentUnavailableView("No Files", systemImage: "doc")
                }
            }
            // Track the live column count so keyboard arrows can navigate the grid in 2D.
            .background {
                if layout == .gallery {
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { appState.fileGridColumns = FileCollectionLayout.galleryColumnCount(for: geo.size.width) }
                            .onChange(of: geo.size.width) { _, width in
                                appState.fileGridColumns = FileCollectionLayout.galleryColumnCount(for: width)
                            }
                    }
                }
            }
            // Keep the keyboard-driven selection (single item) visible as it moves. A
            // mouse-driven change skips this — the clicked item is already on screen.
            .onChange(of: appState.selectedFileIDs) { _, ids in
                if skipSelectionScroll { skipSelectionScroll = false; return }
                guard ids.count == 1, let id = ids.first else { return }
                withAnimation { proxy.scrollTo(id, anchor: .center) }
            }
            // Selecting a playlist (or re-selecting the current one) asks to re-center
            // the resume file even when the selection didn't move. Deferred a layout
            // pass so a just-switched playlist's items exist for `scrollTo` to land on.
            .onChange(of: appState.scrollSelectionToken) { _, _ in
                guard appState.selectedFileIDs.count == 1, let id = appState.selectedFileIDs.first else { return }
                DispatchQueue.main.async { withAnimation { proxy.scrollTo(id, anchor: .center) } }
            }
            // Returning from the player selects the last-played file before this view
            // mounts, so `onChange` never fires for it. Defer past the first layout pass
            // so the lazy container has realized items for `scrollTo` to land on.
            .onAppear {
                guard appState.selectedFileIDs.count == 1, let id = appState.selectedFileIDs.first else { return }
                DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    /// One file's cell, wrapped with the shared tap (select / double-click to play)
    /// and context menu. The layout positions it.
    private func item(_ file: PlaylistFile) -> some View {
        cell(FileCellConfiguration(
            file: file,
            playlist: playlist,
            isSelected: appState.selectedFileIDs.contains(file.id),
            isRenaming: renamingID == file.id,
            isStripping: appState.strippingFileIDs.contains(file.id),
            draftName: $draftName,
            onCommitRename: { commitRename(file) },
            onCancelRename: { renamingID = nil }
        ))
        .id(file.id)
        // A single tap gesture branching on the event's click count: attaching a
        // separate `count: 2` gesture would force SwiftUI to delay the single click
        // until the double-click interval elapses, making selection feel laggy.
        .onTapGesture { handleTap(file) }
        .contextMenu {
            FileContextMenu(
                file: file,
                playlist: playlist,
                onRename: { beginRename(file) },
                onRemoveAudio: { appState.requestAudioStrip(targets(for: file)) },
                onDelete: { confirmDelete(targets(for: file)) }
            )
        }
    }

    // MARK: - Data

    /// The filtered, sorted files for the selected playlist, cached on `AppState`
    /// and kept in sync with the tag/service filter.
    private var visibleFiles: [PlaylistFile] {
        appState.filteredFiles
    }

    /// The files a context-menu action targets: the multi-selection when the clicked
    /// item is part of it, otherwise just that item.
    private func targets(for file: PlaylistFile) -> [PlaylistFile] {
        FileSelection.actionTargets(for: file, selection: appState.selectedFileIDs, visible: visibleFiles)
    }

    // MARK: - Selection

    /// A double-click plays the file; a single click adjusts the selection.
    private func handleTap(_ file: PlaylistFile) {
        if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
            appState.beginPlayback(of: playlist, startingAt: file)
        } else {
            handleClick(file)
        }
    }

    private func handleClick(_ file: PlaylistFile) {
        let before = appState.selectedFileIDs
        FileSelection.apply(
            click: file.id,
            modifiers: NSEvent.modifierFlags,
            in: visibleFiles,
            selection: &appState.selectedFileIDs,
            anchor: &anchor
        )
        if appState.selectedFileIDs != before { skipSelectionScroll = true }
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
