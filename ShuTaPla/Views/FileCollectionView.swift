//
//  FileCollectionView.swift
//  ShuTaPla
//
//  The Manager center file browser, shared by the list and gallery presentations.
//  Both show the active scope's filtered files (`AppState.managerFileIDs`) with the same
//  interactions — click / shift-click / cmd-click selection, double-click to play,
//  inline rename, a per-item context menu, and keyboard-selection auto-scroll —
//  differing only in layout (a windowed `VirtualList` of `FileListRow`s vs a windowed
//  `GalleryPagedList` of `GalleryCell` thumbnails chunked into grid rows), chosen by the
//  `layout` parameter. One concrete view type
//  regardless of layout, so switching presentation keeps this view's identity (and its
//  scroll/selection `@State`) rather than tearing the whole browser down and rebuilding it.
//

import SwiftUI
import SwiftData
import AppKit

/// Which presentation the shared browser draws.
nonisolated enum FileCollectionLayout {
    case list
    case gallery

    /// Gallery grid metrics for the `LazyVGrid` columns.
    /// `galleryMinItemWidth` is the default adaptive minimum when a playlist hasn't chosen
    /// its own; `galleryMaxRatio` sets the adaptive maximum as a multiple of the minimum, so
    /// a wider minimum still leaves headroom for the grid to repack before adding a column.
    static let galleryMinItemWidth: CGFloat = 200
    static let galleryMaxRatio: CGFloat = 1.8
    static let gallerySpacing: CGFloat = 4

    /// A gallery tile's inner padding (matched by `GalleryCell`) and the fixed chrome added below
    /// its 4:3 thumbnail — the caption gap plus the two-line caption's reserved height. The chrome
    /// is deliberately generous so a tile framed to `rowHeight(tileWidth:)` never clips; any slack
    /// falls harmlessly below the caption.
    static let galleryTilePadding: CGFloat = 3
    static let galleryCaptionChrome: CGFloat = 42

    /// The adaptive grid's (minimum, maximum) tile widths for a playlist's chosen minimum.
    /// A `nil` choice (never set) falls back to `galleryMinItemWidth`; the maximum is always
    /// `galleryMaxRatio ×` the minimum.
    static func gridMetrics(min chosen: Double?) -> (min: CGFloat, max: CGFloat) {
        let minimum = chosen.map { CGFloat($0) } ?? galleryMinItemWidth
        return (minimum, minimum * galleryMaxRatio)
    }

    /// The column count and tile width for an available `width`, replicating `LazyVGrid`'s
    /// `.adaptive(minimum:maximum:)` packing so a `VirtualList` gallery can size its rows without
    /// measuring rendered cells: fit as many `min`-wide columns as the width allows (at least one),
    /// then widen each to share the width evenly, capped at `max`.
    static func gridLayout(width: CGFloat, min: CGFloat, max: CGFloat, spacing: CGFloat) -> (columns: Int, tileWidth: CGFloat) {
        guard width > 0, min > 0 else { return (1, Swift.max(0, width)) }
        let columns = Swift.max(1, Int((width + spacing) / (min + spacing)))
        let tileWidth = (width - CGFloat(columns - 1) * spacing) / CGFloat(columns)
        return (columns, Swift.min(tileWidth, max))
    }

    /// A gallery row's fixed height for a given tile width: the 4:3 thumbnail (inset by the tile
    /// padding on each side) plus the caption/padding chrome. The whole windowing scheme relies on
    /// every row being exactly this tall.
    static func rowHeight(tileWidth: CGFloat) -> CGFloat {
        (tileWidth - 2 * galleryTilePadding) * 3 / 4 + galleryCaptionChrome
    }
}

/// The two Manager inputs that ask the file list to scroll, compared as one value so a
/// playlist switch — which changes both at once — resolves in a single, order-independent
/// step: a changed `token` reveals the current file instantly (switch / re-click), while
/// a bare `selection` change (keyboard move) animates into view.
private struct FileScrollRequest: Equatable {
    var selection: Set<UUID>
    var token: Int
}

/// The per-file inputs a cell needs: its selection / rename / stripping state and
/// the rename field's draft binding and commit/cancel handlers.
struct FileCellConfiguration {
    let file: PlaylistFile
    let playlist: Playlist
    let isSelected: Bool
    /// This file is the playlist's playback cursor (`currentFileID`) — where playback
    /// sits or would resume, marked independently of the multi-select highlight.
    let isCurrent: Bool
    let isRenaming: Bool
    let isStripping: Bool
    let draftName: Binding<String>
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void
}

struct FileCollectionView: View {
    let playlist: Playlist
    let layout: FileCollectionLayout
    let confirmDelete: ([PlaylistFile]) -> Void
    let reportError: (String) -> Void

    @Environment(AppState.self) private var appState

    @State private var anchor: PersistentIdentifier?
    @State private var renamingID: UUID?
    @State private var draftName = ""
    // A mouse click already targets a visible item, so the auto-scroll that keeps the
    // keyboard selection centered would only jar the view. Set when a click changes
    // the selection, consumed by the next selection-change scroll.
    @State private var skipSelectionScroll = false
    // Each surface's re-center scroll, applied by its `VirtualList`: an instant jump for a switch /
    // re-click, an animated reveal for a keyboard move. The list command carries a row index; the
    // gallery command a grid-row index (item index / columns).
    @State private var fileScrollCommand: VirtualScrollCommand?
    @State private var galleryScrollCommand: VirtualScrollCommand?

    /// The `ids` index of the current playback cursor (`currentFileID`) — where the list opens
    /// with no travel. `nil` when nothing is current or it is filtered out of the sequence.
    private func currentFileIndex(in ids: [PersistentIdentifier]) -> Int? {
        guard let uuid = playlist.currentFileID, let id = appState.fileIdentifier(for: uuid) else { return nil }
        return ids.firstIndex(of: id)
    }

    /// The `ids` index to scroll to for a single-file selection. `nil` for an empty or multi-file
    /// selection (nothing to reveal), or a selection filtered out of the sequence.
    private func scrollIndex(_ selection: Set<UUID>, in ids: [PersistentIdentifier]) -> Int? {
        guard selection.count == 1, let uuid = selection.first,
              let id = appState.fileIdentifier(for: uuid) else { return nil }
        return ids.firstIndex(of: id)
    }

    var body: some View {
        // Bind the sequence once so the layouts and the empty-state overlay share it rather
        // than reading `managerFileIDs` twice. Reading it here registers the `sequences.version`
        // Observation dependency that drives re-renders.
        let ids = visibleFileIDs
        Group {
            switch layout {
            case .list: fileList(ids)
            case .gallery: gallery(ids)
            }
        }
        .overlay {
            if ids.isEmpty {
                ContentUnavailableView("No Files", systemImage: "doc")
            }
        }
    }

    // MARK: - List

    /// The list presentation: a windowed `VirtualList` of `FileListRow`s. It sizes its content
    /// from the row count alone and builds only the visible band, so a switch to a large playlist
    /// materializes ~a screenful of rows, never the whole sequence — and it opens at the current
    /// file (`initialTarget`) with no travel, driven onward by `fileScrollCommand`.
    private func fileList(_ ids: [PersistentIdentifier]) -> some View {
        VirtualList(
            count: ids.count,
            rowHeight: AppConstants.fileListRowHeight,
            initialTarget: currentFileIndex(in: ids),
            command: fileScrollCommand
        ) { index in
            if ids.indices.contains(index) {
                FileListRow(
                    id: ids[index],
                    playlist: playlist,
                    role: .manager,
                    renamingID: renamingID,
                    draftName: $draftName,
                    onTap: { handleTap($0) },
                    onCommitRename: { commitRename($0) },
                    onCancelRename: { renamingID = nil },
                    onRename: { beginRename($0) },
                    onRemoveAudio: { appState.requestAudioStrip(targets(for: $0)) },
                    onDownload: { appState.downloadFiles(targets(for: $0)) },
                    onDelete: { confirmDelete(targets(for: $0)) }
                )
            }
        }
        .onChange(of: FileScrollRequest(selection: appState.managerSelection, token: appState.managerScrollToken)) { old, new in
            routeScroll(old: old, new: new, ids: ids) { index, animated in
                fileScrollCommand = VirtualScrollCommand(index: index, animated: animated, token: new.token)
            }
        }
    }

    // MARK: - Gallery

    /// The gallery presentation: a windowed `GalleryPagedList` whose pages chunk the ids into grid
    /// rows of cells. The container width drives `FileCollectionLayout.gridLayout` — the column count
    /// and tile width, computed rather than measured, so each row's height is known up front. It
    /// opens at the current file's row (no travel), driven onward by `galleryScrollCommand`, and
    /// publishes the column count to `fileGridColumns` so keyboard arrows navigate in 2D. Its
    /// identity is the sequence and the column count: a change to either discards the whole tree — no
    /// page/cell reuse — so a switch can't leave the prior playlist's thumbnails painted and a
    /// tile-size change can't reflow under a stale offset; the fresh tree rebuilds already positioned.
    private func gallery(_ ids: [PersistentIdentifier]) -> some View {
        GeometryReader { proxy in
            let metrics = FileCollectionLayout.gridMetrics(min: playlist.preferences.galleryMinItemWidth)
            let available = proxy.size.width - 2 * FileCollectionLayout.gallerySpacing
            let grid = FileCollectionLayout.gridLayout(width: available, min: metrics.min, max: metrics.max, spacing: FileCollectionLayout.gallerySpacing)
            let tileHeight = FileCollectionLayout.rowHeight(tileWidth: grid.tileWidth)
            GalleryPagedList(
                ids: ids,
                columns: grid.columns,
                tileWidth: grid.tileWidth,
                tileHeight: tileHeight,
                spacing: FileCollectionLayout.gallerySpacing,
                initialTarget: currentFileIndex(in: ids),
                command: galleryScrollCommand
            ) { id in
                galleryCell(id)
            }
            .id([AnyHashable(playlist.persistentModelID), AnyHashable(grid.columns)])
            // Keep the keyboard navigator's column stride matched to the packing.
            .onChange(of: grid.columns, initial: true) { _, count in
                if appState.fileGridColumns != count { appState.fileGridColumns = count }
            }
            .onChange(of: FileScrollRequest(selection: appState.managerSelection, token: appState.managerScrollToken)) { old, new in
                routeScroll(old: old, new: new, ids: ids) { index, animated in
                    galleryScrollCommand = VirtualScrollCommand(index: index, animated: animated, token: new.token)
                }
            }
        }
    }

    /// One gallery tile: the resolved file wrapped with the shared tap / context menu.
    @ViewBuilder
    private func galleryCell(_ id: PersistentIdentifier) -> some View {
        if let file = appState.file(for: id) {
            item(file) { config in
                GalleryCell(
                    file: config.file,
                    playlist: config.playlist,
                    isSelected: config.isSelected,
                    isCurrent: config.isCurrent,
                    isRenaming: config.isRenaming,
                    isStripping: config.isStripping,
                    draftName: config.draftName,
                    onCommitRename: config.onCommitRename,
                    onCancelRename: config.onCancelRename
                )
            }
        }
    }

    /// Routes a scroll request to the active layout's positioner, so a playlist switch — which
    /// bumps the token *and* moves the selection at once — resolves independently of `onChange`
    /// firing order: a changed token jumps to the current file instantly, a bare selection change
    /// (a keyboard move) animates it into view, and a mouse click that already targets a visible
    /// row is left alone. `reveal(index, animated)` performs the layout-specific scroll.
    private func routeScroll(
        old: FileScrollRequest, new: FileScrollRequest, ids: [PersistentIdentifier],
        reveal: (Int, Bool) -> Void
    ) {
        if new.token != old.token {
            if let index = scrollIndex(new.selection, in: ids) { reveal(index, false) }
        } else if skipSelectionScroll {
            skipSelectionScroll = false
        } else if let index = scrollIndex(new.selection, in: ids) {
            reveal(index, true)
        }
    }

    /// One file's cell — the layout supplies the concrete cell (`FileRowView`/`GalleryCell`)
    /// through `cell`, and this wraps it with the shared tap (select / double-click to play)
    /// and context menu. A generic *function*, so both layouts resolve within this one view
    /// type. The layout positions it.
    private func item<Cell: View>(
        _ file: PlaylistFile,
        @ViewBuilder cell: (FileCellConfiguration) -> Cell
    ) -> some View {
        cell(FileCellConfiguration(
            file: file,
            playlist: playlist,
            isSelected: appState.managerSelection.contains(file.id),
            isCurrent: file.id == playlist.currentFileID,
            isRenaming: renamingID == file.id,
            isStripping: appState.strippingFileIDs.contains(file.id),
            draftName: $draftName,
            onCommitRename: { commitRename(file) },
            onCancelRename: { renamingID = nil }
        ))
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
                onDownload: { appState.downloadFiles(targets(for: file)) },
                onDelete: { confirmDelete(targets(for: file)) }
            )
        }
    }

    // MARK: - Data

    /// The active scope's filtered, sorted file identifiers, derived store-side and resolved
    /// row-by-row by the lazy containers above.
    private var visibleFileIDs: [PersistentIdentifier] {
        appState.managerFileIDs
    }

    /// The files a context-menu action targets: the multi-selection when the clicked item is
    /// part of it, otherwise just that item. `managerSelectionFiles()` is already the visible
    /// selection, so passing it as `visible` resolves only the selection, not the whole list.
    private func targets(for file: PlaylistFile) -> [PlaylistFile] {
        FileSelection.actionTargets(for: file, selection: appState.managerSelection, visible: appState.managerSelectionFiles())
    }

    // MARK: - Selection

    /// A double-click plays the file; a single click adjusts the selection.
    private func handleTap(_ file: PlaylistFile) {
        if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
            appState.playFromManager(of: playlist, startingAt: file)
        } else {
            handleClick(file)
        }
    }

    private func handleClick(_ file: PlaylistFile) {
        let before = appState.managerSelection
        // Read the modifiers from the click that triggered this handler, not the
        // global keyboard state at handler-run time: `onTapGesture` fires on mouse-up,
        // so a shift/cmd released a few milliseconds early would otherwise downgrade a
        // range/toggle click to a plain select and collapse the multi-selection.
        FileSelection.apply(
            click: file,
            modifiers: NSApp.currentEvent?.modifierFlags ?? [],
            ids: visibleFileIDs,
            uuid: { appState.file(for: $0)?.id },
            selection: &appState.managerSelection,
            anchor: &anchor
        )
        if appState.managerSelection != before { skipSelectionScroll = true }
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
