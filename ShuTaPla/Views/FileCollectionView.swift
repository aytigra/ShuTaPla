//
//  FileCollectionView.swift
//  ShuTaPla
//
//  The Manager center file browser, shared by the list and gallery presentations.
//  Both show the active scope's filtered files (`AppState.managerFiles`) with the same
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

    /// Gallery grid metrics for the `LazyVGrid` columns.
    static let galleryMinItemWidth: CGFloat = 150
    static let galleryMaxItemWidth: CGFloat = 220
    static let gallerySpacing: CGFloat = 12

    /// Derives the gallery's column count from the leading-edge x of every laid-out
    /// cell: cells in the same column share a leading edge, so the number of distinct
    /// edges (to the nearest point, absorbing sub-pixel drift) is the column count.
    /// Measuring the rendered frames keeps the keyboard navigator's stride matched to
    /// whatever `LazyVGrid`'s adaptive packing actually produced, rather than
    /// re-deriving the packing and risking a drift at the `galleryMaxItemWidth` cap.
    static func columnCount(fromCellMinXs minXs: [CGFloat]) -> Int {
        let distinct = Set(minXs.map { $0.rounded() })
        return max(1, distinct.count)
    }
}

/// Leading-edge x of each laid-out gallery cell, collected so the column count can be
/// measured from the real layout (see `FileCollectionLayout.columnCount(fromCellMinXs:)`).
private struct GalleryCellMinXKey: PreferenceKey {
    static let defaultValue: [CGFloat] = []
    static func reduce(value: inout [CGFloat], nextValue: () -> [CGFloat]) {
        value.append(contentsOf: nextValue())
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

    /// Coordinate space the gallery cells report their frames in, so a cell's leading
    /// edge is stable under vertical scroll.
    private let gridSpace = "fileGrid"

    @State private var anchor: UUID?
    @State private var renamingID: UUID?
    @State private var draftName = ""
    // A mouse click already targets a visible item, so the auto-scroll that keeps the
    // keyboard selection centered would only jar the view. Set when a click changes
    // the selection, consumed by the next selection-change scroll.
    @State private var skipSelectionScroll = false

    private var columns: [GridItem] {
        [GridItem(
            .adaptive(minimum: FileCollectionLayout.galleryMinItemWidth, maximum: FileCollectionLayout.galleryMaxItemWidth),
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
                                // Publish this cell's leading edge so the live column
                                // count can be measured from the real layout. Vertical
                                // scroll doesn't move it, so the set of edges is stable.
                                .background {
                                    GeometryReader { geo in
                                        Color.clear.preference(
                                            key: GalleryCellMinXKey.self,
                                            value: [geo.frame(in: .named(gridSpace)).minX]
                                        )
                                    }
                                }
                        }
                    }
                    .padding(FileCollectionLayout.gallerySpacing)
                }
            }
            .coordinateSpace(name: gridSpace)
            .overlay {
                if visibleFiles.isEmpty {
                    ContentUnavailableView("No Files", systemImage: "doc")
                }
            }
            // Track the live column count so keyboard arrows can navigate the grid in 2D.
            .onPreferenceChange(GalleryCellMinXKey.self) { minXs in
                let count = FileCollectionLayout.columnCount(fromCellMinXs: minXs)
                Task { @MainActor in
                    if appState.fileGridColumns != count { appState.fileGridColumns = count }
                }
            }
            // Keep the keyboard-driven selection (single item) visible as it moves. A
            // mouse-driven change skips this — the clicked item is already on screen.
            .onChange(of: appState.managerSelection) { _, ids in
                if skipSelectionScroll { skipSelectionScroll = false; return }
                guard ids.count == 1, let id = ids.first else { return }
                withAnimation { proxy.scrollTo(id, anchor: .center) }
            }
            // Selecting a playlist (or re-selecting the current one) asks to re-center
            // the resume file even when the selection didn't move. Deferred a layout
            // pass so a just-switched playlist's items exist for `scrollTo` to land on.
            .onChange(of: appState.managerScrollToken) { _, _ in
                guard appState.managerSelection.count == 1, let id = appState.managerSelection.first else { return }
                DispatchQueue.main.async { withAnimation { proxy.scrollTo(id, anchor: .center) } }
            }
            // Returning from the player selects the last-played file before this view
            // mounts, so `onChange` never fires for it. Defer past the first layout pass
            // so the lazy container has realized items for `scrollTo` to land on.
            .onAppear {
                guard appState.managerSelection.count == 1, let id = appState.managerSelection.first else { return }
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
            isSelected: appState.managerSelection.contains(file.id),
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

    /// The active scope's filtered, sorted files, cached on `AppState` and kept in sync
    /// with the tag/service filter.
    private var visibleFiles: [PlaylistFile] {
        appState.managerFiles
    }

    /// The files a context-menu action targets: the multi-selection when the clicked
    /// item is part of it, otherwise just that item.
    private func targets(for file: PlaylistFile) -> [PlaylistFile] {
        FileSelection.actionTargets(for: file, selection: appState.managerSelection, visible: visibleFiles)
    }

    // MARK: - Selection

    /// A double-click plays the file; a single click adjusts the selection.
    private func handleTap(_ file: PlaylistFile) {
        if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
            appState.beginManagerPlayback(of: playlist, startingAt: file)
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
            click: file.id,
            modifiers: NSApp.currentEvent?.modifierFlags ?? [],
            in: visibleFiles,
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
