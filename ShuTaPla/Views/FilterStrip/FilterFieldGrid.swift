//
//  FilterFieldGrid.swift
//  ShuTaPla
//
//  The expanded strip's four labelled token fields. Which rule a tag obeys is which field it was
//  typed into, so the four are peers in one grid rather than a control with a mode — the grid packs
//  them into four, two or one column by the width it is given (`FilterStripLayout`).
//
//  Adding and removing both go through `toggleFilterTag`, the one path a `TagFilter` row is created
//  and destroyed by: the first tag typed into an unfiltered playlist inserts the row, and taking the
//  last one out of the last field deletes it — taking any search saved over it, since the name
//  described a combination that no longer exists.
//

import SwiftUI

struct FilterFieldGrid: View {
    let playlist: Playlist

    @Environment(AppState.self) private var appState

    @State private var width: CGFloat = 0
    /// The field whose suggestion dropdown is open. That dropdown overhangs whatever is below and
    /// beside it, and `zIndex` orders siblings only, so both the cell within its row and the row
    /// within the stack are raised. (The grid as a whole is raised over the name row by its host.)
    @State private var editingField: TagFilterField?

    var body: some View {
        // Plain stacks rather than a `LazyVGrid`: laziness buys nothing over four fields, and the
        // grid gave no dependable way to lift the open cell's dropdown over the cells around it.
        VStack(alignment: .leading, spacing: 10) {
            ForEach(rows, id: \.self) { row in
                HStack(alignment: .top, spacing: 12) {
                    ForEach(row, id: \.self) { field in
                        cell(field)
                            // Equal shares of the row, so the columns line up down the grid.
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .zIndex(editingField == field ? 1 : 0)
                    }
                }
                .zIndex(row.contains { $0 == editingField } ? 1 : 0)
            }
        }
        // Integer widths so successive sub-pixel measurements settle rather than cycling. The grid
        // fills whatever it is given at any column count, so measuring it can't feed back into the
        // count it chooses.
        .onGeometryChange(for: CGFloat.self) { $0.size.width.rounded(.down) } action: { width = $0 }
    }

    private func cell(_ field: TagFilterField) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(field.label)
                .font(.caption)
            TagTokenField(
                tokens: playlist.currentFilter?[field] ?? [],
                knownTags: playlist.tagFrequency,
                allowsCreate: false,
                placeholder: "Any tag",
                onAdd: { appState.toggleFilterTag($0, in: field, on: playlist) },
                onRemove: { appState.toggleFilterTag($0, in: field, on: playlist) },
                // Moving between two fields can report the new one's open before the old one's
                // close, so a close only clears the cell it names.
                onEditingChanged: { open in
                    if open { editingField = field } else if editingField == field { editingField = nil }
                }
            )
        }
    }

    /// The four fields split into rows of the current column count — which divides four evenly at
    /// every step, so no row is ever short and the cells all keep the same width.
    private var rows: [[TagFilterField]] {
        let fields = TagFilterField.allCases
        let perRow = FilterStripLayout.columns(forWidth: width)
        return stride(from: 0, to: fields.count, by: perRow).map { Array(fields[$0..<$0 + perRow]) }
    }
}
