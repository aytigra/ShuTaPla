//
//  ManagerSelectionPreview.swift
//  ShuTaPla
//
//  The read-only "currently edited" preview below the Manager tag editor. The editor keeps a file
//  selected after a tag edit pushes it out of the effective filter (add the first tag under an
//  "untagged" filter → it leaves the list but stays editable), so the list no longer shows what the
//  tag field acts on. This makes that out-of-view selection legible: one selected file as a read-only
//  `GalleryCell`, several as a summary line over a scrolling list of their names.
//

import SwiftUI
import SwiftData

/// The multi-file summary line's text and whether it carries the filtered-out info icon, derived
/// purely from the counts:
/// - none filtered out → `"N selected"` (no icon)
/// - some (not all) filtered out → `"N selected · M filtered out"` (icon)
/// - all filtered out → `"All filtered out"` (icon)
nonisolated struct ManagerSelectionSummary: Equatable {
    let text: String
    let showsIcon: Bool

    init(selectedCount: Int, filteredOutCount: Int) {
        if filteredOutCount == 0 {
            text = "\(selectedCount) selected"
            showsIcon = false
        } else if filteredOutCount >= selectedCount {
            text = "All filtered out"
            showsIcon = true
        } else {
            text = "\(selectedCount) selected · \(filteredOutCount) filtered out"
            showsIcon = true
        }
    }
}

struct ManagerSelectionPreview: View {
    let playlist: Playlist

    @Environment(AppState.self) private var appState

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: 150, alignment: .topLeading)
    }

    @ViewBuilder
    private var content: some View {
        // Resolve the whole selection (not just its visible subset — the point is to show the
        // filtered-out file still in the editor) refault-free: `fileIdentifier`/`file(for:)` are
        // identifier and `model(for:)` lookups, never the `includePendingChanges = false` object
        // fetch that would discard a cell's just-merged metadata. Reading `managerSelection` here
        // re-renders on a selection change; the multi-file branch reads `filteredOutSelectionCount`
        // (→ `sequences.version`) so a tag edit that shifts membership updates the summary too.
        let selected = appState.managerSelection
            .compactMap { appState.fileIdentifier(for: $0) }
            .compactMap { appState.file(for: $0) }
            .sorted { $0.sortOrder < $1.sortOrder }

        switch selected.count {
        case 0:
            EmptyView()
        case 1:
            single(selected[0])
        default:
            multi(selected)
        }
    }

    /// One selected file: a read-only `GalleryCell` — its thumbnail, name caption, and badges are
    /// the whole preview. Held in a scoped-access session so the thumbnail read appends to a
    /// pre-resolved folder URL rather than resolving the bookmark for the lone file.
    private func single(_ file: PlaylistFile) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            GalleryCell(
                file: file,
                playlist: playlist,
                isSelected: false,
                isCurrent: false,
                isRenaming: false,
                isStripping: false,
                draftName: .constant(""),
                onCommitRename: {},
                onCancelRename: {}
            )
            .padding(.top, 8)
        }
        .padding(.horizontal, 12)
        .browsingSession(for: playlist, folderAccess: appState.folderAccess)
    }

    /// Several selected files: the summary line over a lazily rendered, self-scrolling list of their
    /// names — plain rows, no marks or dimming — that owns the remaining height instead of growing
    /// the sidebar.
    private func multi(_ files: [PlaylistFile]) -> some View {
        let summary = ManagerSelectionSummary(
            selectedCount: files.count,
            filteredOutCount: appState.filteredOutSelectionCount
        )
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                if summary.showsIcon {
                    Image(systemName: "info.circle")
                }
                Text(summary.text)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(files, id: \.persistentModelID) { file in
                        Text(file.fileName)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: 150)
        }
        .padding(.horizontal, 12)
    }
}
