//
//  FileCollectionView.swift
//  ShuTaPla
//
//  The Manager center file browser, shared by the list and gallery presentations.
//  Both show the active scope's filtered files (`AppState.managerFileIDs`) with the same
//  interactions — click / shift-click / cmd-click selection, double-click to play,
//  inline rename, a per-item context menu, and keyboard-selection auto-scroll —
//  differing only in layout (the shared `FileListSurface` vs a windowed
//  `GalleryPagedList` of `FileGalleryCell` thumbnails chunked into grid rows), chosen by the
//  `layout` parameter. One concrete view type
//  regardless of layout, so switching presentation keeps this view's identity (and its
//  scroll/selection `@State`) rather than tearing the whole browser down and rebuilding it.
//

import SwiftUI
import SwiftData
import AppKit

/// Which presentation the shared browser draws. The gallery's column packing and row geometry
/// live in `GalleryGrid`.
nonisolated enum FileCollectionLayout {
    case list
    case gallery
}

/// The two Manager inputs that ask the file list to scroll, compared as one value so a
/// playlist switch — which changes both at once — resolves in a single, order-independent
/// step: a changed `token` reveals the current file instantly (switch / re-click), while
/// a bare `selection` change (keyboard move) animates into view.
private struct FileScrollRequest: Equatable {
    var selection: Set<UUID>
    var token: Int
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
    // The active surface's re-center scroll, applied by its `PagedList`: an instant jump for a
    // switch / re-click, an animated reveal for a keyboard move. One command serves both layouts —
    // they're mutually exclusive here — carrying an item index the gallery maps to its grid row.
    @State private var scrollCommand: ScrollCommand?

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
        // One scroll router for both layouts — they share `scrollCommand` and are mutually exclusive
        // here. A changed token jumps to the current file (switch / re-click), a bare selection change
        // (keyboard move) tracks it into view, and a click that already targets a visible row is left
        // alone. The instant open-at-current on a playlist switch is the list/gallery `.id` remount.
        .onChange(of: FileScrollRequest(selection: appState.managerSelection, token: appState.managerScrollToken)) { old, new in
            routeScroll(old: old, new: new, ids: ids) { index, mode in
                scrollCommand = ScrollCommand(index: index, mode: mode, token: new.token)
            }
        }
        // Hold one scoped-access session for the browsed folder so the cells' thumbnail/metadata
        // reads append to a pre-resolved URL instead of resolving the bookmark per file.
        .browsingSession(for: playlist, folderAccess: appState.folderAccess)
    }

    // MARK: - List

    /// The list presentation: the shared `FileListSurface`, given the Manager's `.manager` role and
    /// its per-row action closures. It opens at the current file with no travel and windows whole
    /// pages, so a switch to a large playlist materializes ~a screenful of rows, never the sequence.
    private func fileList(_ ids: [PersistentIdentifier]) -> some View {
        FileListSurface(
            ids: ids,
            playlist: playlist,
            role: .manager,
            targetIndex: currentFileIndex(in: ids),
            command: scrollCommand,
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

    // MARK: - Gallery

    /// The gallery presentation: a windowed `GalleryPagedList` whose pages chunk the ids into grid
    /// rows of cells. The container width drives `GalleryGrid.gridLayout` — the column count
    /// and tile width, computed rather than measured, so each row's height is known up front. It
    /// opens at the current file's row (no travel), driven onward by `scrollCommand`, and
    /// publishes the column count to `fileGridColumns` so keyboard arrows navigate in 2D. Its
    /// identity is the sequence and the column count: a change to either discards the whole tree — no
    /// page/cell reuse — so a switch can't leave the prior playlist's thumbnails painted and a
    /// tile-size change can't reflow under a stale offset; the fresh tree rebuilds already positioned.
    private func gallery(_ ids: [PersistentIdentifier]) -> some View {
        GeometryReader { proxy in
            let metrics = GalleryGrid.gridMetrics(min: playlist.preferences.galleryMinItemWidth)
            let available = proxy.size.width - 2 * GalleryGrid.gallerySpacing
            let grid = GalleryGrid.gridLayout(width: available, min: metrics.min, max: metrics.max, spacing: GalleryGrid.gallerySpacing)
            let tileHeight = GalleryGrid.rowHeight(tileWidth: grid.tileWidth)
            GalleryPagedList(
                ids: ids,
                columns: grid.columns,
                tileWidth: grid.tileWidth,
                tileHeight: tileHeight,
                spacing: GalleryGrid.gallerySpacing,
                initialTarget: currentFileIndex(in: ids),
                command: scrollCommand
            ) { id in
                FileGalleryCell(
                    id: id,
                    playlist: playlist,
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
            .id([AnyHashable(playlist.persistentModelID), AnyHashable(grid.columns)])
            // Keep the keyboard navigator's column stride matched to the packing.
            .onChange(of: grid.columns, initial: true) { _, count in
                if appState.fileGridColumns != count { appState.fileGridColumns = count }
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
        reveal: (Int, ScrollReveal) -> Void
    ) {
        if new.token != old.token {
            if let index = scrollIndex(new.selection, in: ids) { reveal(index, .jump) }
        } else if skipSelectionScroll {
            skipSelectionScroll = false
        } else if let index = scrollIndex(new.selection, in: ids) {
            reveal(index, .track)
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
