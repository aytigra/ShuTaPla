//
//  FilterSummaryLine.swift
//  ShuTaPla
//
//  What a saved search holds, under its name: each filled field's short lead-in followed by that
//  field's tags as chips. The tags are the part that tells two searches apart, and set as words in a
//  sentence they read as no different from the labels introducing them — so they are the same pills
//  the fields above show, and a row reads as the grid it fills.
//

import SwiftUI

struct FilterSummaryLine: View {
    let filter: TagFilter

    var body: some View {
        // Wrapping rather than one truncated line: a name cut short is what the row exists to show,
        // and the panel already scrolls once its rows outgrow it. A field is one subview of the
        // outer flow, so a wrap falls between blocks and never strands a lead-in at one end of a
        // line with its tags at the other — a block only breaks internally, on its own inner flow,
        // once it is too wide for a line of its own.
        FlowLayout(spacing: 14, lineSpacing: 4) {
            ForEach(filter.filledFields, id: \.field) { filled in
                block(filled.field, tags: filled.tags)
            }
        }
    }

    private func block(_ field: TagFilterField, tags: [String]) -> some View {
        FlowLayout(spacing: 4, lineSpacing: 4) {
            Text(field.shortLabel.uppercased())
                .font(.caption2)
                .foregroundStyle(.secondary)
            ForEach(tags, id: \.self) { tag in
                chip(tag, excluded: field.excludes)
            }
        }
    }

    /// Excluding tags are tinted apart from requiring ones — the lead-ins differ by a single word,
    /// and a row is skimmed rather than read.
    private func chip(_ tag: String, excluded: Bool) -> some View {
        Text(tag)
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background((excluded ? Color.red : Color.accentColor).opacity(0.18), in: Capsule())
    }
}
