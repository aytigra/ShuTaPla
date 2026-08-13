//
//  TagTokenField.swift
//  ShuTaPla
//
//  A reusable multiselect-with-autocomplete tag control. Selected tags render as
//  removable chips inside a bordered field; clicking the field opens an editable
//  text input (it never auto-focuses on appear) with a caret that moves among the
//  chips (arrow-left/right step one, double-left/right jump to the first/last, delete
//  removes the selected one). Typing filters a floating dropdown — ranked by how the
//  tag matches the typed string and then by frequency — that overlays the content
//  below rather than pushing it down; arrow-up/down move its highlight, enter adds
//  the highlighted row. Shared by the tag editor (which may create new tags) and the
//  filter bar (which selects existing tags only), differing only by `allowsCreate`
//  and the per-chip menu.
//
//  The text input is a thin `NSTextField` wrapper so focus and the caret-edge key
//  commands come straight from AppKit: it reports begin/end editing and routes
//  `delete`/arrows/`return`/`esc` only at the caret edges. Dismissal is the shared
//  `ClickOutsideMonitor`, backing the field while it edits and told how far the open
//  dropdown reaches below it — so a mouse-down on any other control or a playlist ends
//  editing without swallowing that click, and dropping the input is what gives up focus
//  (AppKit hands the first responder back to the window when it leaves the hierarchy).
//

import SwiftUI
import AppKit

/// One row of the suggestion dropdown: an existing tag with its frequency, or — in a
/// create-enabled field — the typed string offered as a brand-new tag.
enum TagOption: Identifiable, Hashable {
    case existing(String, Int)
    case create(String)

    var tag: String {
        switch self {
        case .existing(let tag, _), .create(let tag): return tag
        }
    }

    var id: String {
        switch self {
        case .existing(let tag, _): return "e:" + tag
        case .create(let tag): return "c:" + tag
        }
    }
}

struct TagTokenField<ChipMenu: View>: View {
    let tokens: [String]
    let knownTags: [String: Int]
    let allowsCreate: Bool
    let placeholder: String
    /// When true the field begins editing (and focuses its input) as soon as it
    /// appears, instead of waiting for a click. The filter bar leaves it off; the
    /// Visual Overlay turns it on so the caret lands in the tag input.
    var autoFocus: Bool = false
    let onAdd: (String) -> Void
    let onRemove: (String) -> Void
    /// Reports when the field starts and stops editing. The dropdown floats over whatever is below
    /// it, and `zIndex` only orders siblings — so a host that stacks several of these (or puts
    /// anything under them) needs to know which one is open to raise it above the rest.
    var onEditingChanged: (Bool) -> Void = { _ in }
    @ViewBuilder let chipMenu: (String) -> ChipMenu

    @State private var input = ""
    @State private var highlighted = 0
    @State private var selectedChip: Int?
    @State private var editing = false
    @State private var controlHeight: CGFloat = 0
    @State private var lastLeft: Date?
    @State private var lastRight: Date?

    // Computed rather than stored: a generic type takes no static storage.
    private static var rowHeight: CGFloat { 30 }

    /// The gap between the field and the dropdown hanging below it.
    private static var dropdownGap: CGFloat { 4 }

    /// The height of every line of the field, chips included. An empty field shows only its
    /// placeholder and an editing one only the text input, each a different height again, so
    /// without one figure for all three a field changes height as it fills — and four of these
    /// standing side by side in the filter grid disagree by whether they happen to hold a tag.
    private let chipHeight: CGFloat = 20

    var body: some View {
        // Ranked once per evaluation and handed down: read as a computed property it re-ranks on
        // every access, and the dropdown, its height, and the monitor's reach all ask for it.
        let suggestions = options
        // How far the open dropdown reaches below the field — its rows plus the gap it hangs at,
        // and nothing at all when there is nothing to suggest.
        let reach = suggestions.isEmpty
            ? 0 : Self.dropdownHeight(optionCount: suggestions.count) + Self.dropdownGap
        field
            .onAppear { if autoFocus { beginEditing() } }
            // Integer height so successive sub-pixel measurements settle rather than
            // cycling (which SwiftUI faults on).
            .onGeometryChange(for: CGFloat.self) { $0.size.height.rounded() } action: { controlHeight = $0 }
            .overlay(alignment: .topLeading) {
                if editing, reach > 0 {
                    dropdown(suggestions).offset(y: controlHeight + Self.dropdownGap)
                }
            }
            // The dropdown is drawn as an overlay, so it lies outside the field's own bounds —
            // the monitor is told that much below itself is still the field's to be clicked.
            .background { if editing { ClickOutsideMonitor(below: reach, onOutside: endEditing) } }
            // While the dropdown is open the field floats above the controls below it.
            .zIndex(editing ? 1 : 0)
    }

    // MARK: - Field

    private var field: some View {
        FlowLayout {
            // Keyed by the tag itself (unique per field), so removing a middle chip
            // keeps each remaining chip's identity — the selection highlight, an open
            // per-chip menu, and the remove transition stay on the right pill.
            ForEach(Array(tokens.enumerated()), id: \.element) { index, tag in
                chip(tag, index: index)
            }
            inputSlot
        }
        .frame(minHeight: chipHeight, alignment: .leading)
        .padding(6)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(editing ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.25))
        )
        .contentShape(Rectangle())
        .onTapGesture { beginEditing() }
    }

    @ViewBuilder
    private var inputSlot: some View {
        if editing {
            TokenTextField(
                text: $input,
                onLeft: moveCaretLeft,
                onRight: moveCaretRight,
                onUp: moveHighlightUp,
                onDown: moveHighlightDown,
                onDeleteBack: deleteAtCaret,
                onSubmit: commit,
                onFocusChange: { focused in if !focused { endEditing() } }
            )
            .frame(minWidth: 90)
            .frame(height: 18)
        } else if tokens.isEmpty {
            Text(placeholder)
                .foregroundStyle(.tertiary)
                .frame(minWidth: 90, alignment: .leading)
        }
    }

    private func chip(_ tag: String, index: Int) -> some View {
        HStack(spacing: 4) {
            Text(tag)
            Button { onRemove(tag) } label: {
                // A padded square hit area around the small glyph so a near-miss removes
                // the tag rather than falling through to the chip's select gesture.
                Image(systemName: "xmark.circle.fill")
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 8)
        // Sized rather than padded, so the chip and the field's other lines are one figure.
        .frame(height: chipHeight)
        .background(Color.accentColor.tagChipFill(selected: selectedChip == index), in: Capsule())
        .overlay {
            if selectedChip == index {
                Capsule().strokeBorder(Color.accentColor, lineWidth: 1)
            }
        }
        .contentShape(Capsule())
        .onTapGesture { beginEditing(selecting: index) }
        .contextMenu { chipMenu(tag) }
    }

    // MARK: - Dropdown

    /// The panel's height for `optionCount` rows, capped at six — past that it runs down over the
    /// content it floats above. Zero rows is no panel, and so nothing for a click to land on.
    static func dropdownHeight(optionCount: Int) -> CGFloat {
        CGFloat(min(optionCount, 6)) * rowHeight
    }

    private func dropdown(_ options: [TagOption]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    // Identify each row by the option's stable id — the same key the
                    // `ForEach` diffs on — so narrowing the list re-renders rows with
                    // the matching tag instead of pinning stale content to a position.
                    ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                        optionRow(option, index: index)
                            .id(option.id)
                    }
                }
            }
            // Follow the arrow-key highlight so it never moves past the visible rows.
            .onChange(of: highlighted) { _, index in
                if options.indices.contains(index) { proxy.scrollTo(options[index].id, anchor: .center) }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.dropdownHeight(optionCount: options.count))
        .floatingPanel(.regularMaterial)
    }

    private func optionRow(_ option: TagOption, index: Int) -> some View {
        Button { add(option) } label: {
            HStack {
                switch option {
                case .existing(let tag, let count):
                    Text(tag)
                    Spacer()
                    Text("\(count)").font(.caption).foregroundStyle(.secondary)
                case .create(let tag):
                    Image(systemName: "plus.circle")
                    Text("Add “\(tag)”")
                    Spacer()
                }
            }
            .padding(.horizontal, 10)
            .frame(height: Self.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(index == highlighted ? Color.accentColor.opacity(0.18) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Focus

    private func beginEditing(selecting chip: Int? = nil) {
        editing = true
        selectedChip = chip
        highlighted = 0
        onEditingChanged(true)
    }

    /// Idempotent: dropping the input is what ends AppKit's editing session, and that session's own
    /// end-editing report arrives back here — after `editing` is already false.
    private func endEditing() {
        guard editing else { return }
        editing = false
        input = ""
        selectedChip = nil
        highlighted = 0
        onEditingChanged(false)
    }

    // MARK: - Caret / chip navigation (only fired at the input's caret edges)

    private func moveCaretLeft() {
        guard tokens.isNotEmpty else { return }
        let now = Date()
        let isDouble = lastLeft.map { now.timeIntervalSince($0) < doublePressInterval } ?? false
        lastLeft = now
        if isDouble {
            selectedChip = 0
        } else {
            selectedChip = selectedChip.map { max(0, $0 - 1) } ?? tokens.count - 1
        }
    }

    private func moveCaretRight() {
        let now = Date()
        let isDouble = lastRight.map { now.timeIntervalSince($0) < doublePressInterval } ?? false
        lastRight = now
        if isDouble {
            if tokens.isNotEmpty { selectedChip = tokens.count - 1 }
            return
        }
        guard let chip = selectedChip else { return }
        selectedChip = chip >= tokens.count - 1 ? nil : chip + 1
    }

    private func moveHighlightUp() {
        guard options.isNotEmpty else { return }
        highlighted = max(0, highlighted - 1)
    }

    private func moveHighlightDown() {
        guard options.isNotEmpty else { return }
        highlighted = min(options.count - 1, highlighted + 1)
    }

    /// Removes the chip at the caret (the selected one, or the last). Returns whether a
    /// chip was removed, so the input only swallows `delete` when it acts on a chip.
    private func deleteAtCaret() -> Bool {
        guard tokens.isNotEmpty else { return false }
        let target = selectedChip ?? tokens.count - 1
        selectedChip = target > 0 ? target - 1 : nil
        onRemove(tokens[target])
        return true
    }

    // MARK: - Commit

    private func commit() {
        let current = options
        if current.isNotEmpty, highlighted < current.count {
            add(current[highlighted])
        } else if allowsCreate {
            addCreated(input)
        }
    }

    private func add(_ option: TagOption) {
        switch option {
        case .existing(let tag, _): commitTag(tag)
        case .create(let tag): addCreated(tag)
        }
    }

    private func addCreated(_ raw: String) {
        let tag = raw.trimmingCharacters(in: .whitespaces)
        guard TagParser.isValidTag(tag) else { return }
        commitTag(tag)
    }

    private func commitTag(_ tag: String) {
        input = ""
        highlighted = 0
        selectedChip = nil
        onAdd(tag)
    }

    // MARK: - Suggestions

    private var options: [TagOption] {
        Self.options(query: input, knownTags: knownTags, selected: tokens, allowsCreate: allowsCreate)
    }

    /// The ranked dropdown for `query`: known tags not already selected, ordered by
    /// how they match the typed string (exact, then prefix, then substring) and then
    /// by frequency. When `allowsCreate` and `query` is a valid tag not already
    /// present, a trailing `.create` row offers it as a new tag.
    static func options(
        query: String,
        knownTags: [String: Int],
        selected: [String],
        allowsCreate: Bool,
        limit: Int = 50
    ) -> [TagOption] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let needle = trimmed.lowercased()
        let chosen = Set(selected.map { $0.lowercased() })

        let ranked = knownTags
            .filter { !chosen.contains($0.key.lowercased()) }
            .filter { needle.isEmpty || $0.key.lowercased().contains(needle) }
            .sorted { a, b in
                let ra = matchRank(a.key.lowercased(), needle: needle)
                let rb = matchRank(b.key.lowercased(), needle: needle)
                if ra != rb { return ra < rb }
                if a.value != b.value { return a.value > b.value }
                return a.key.lowercased() < b.key.lowercased()
            }
            .prefix(limit)
            .map { TagOption.existing($0.key, $0.value) }

        var result = Array(ranked)
        if allowsCreate,
           TagParser.isValidTag(trimmed),
           !chosen.contains(needle),
           !ranked.contains(where: { $0.tag.lowercased() == needle }) {
            result.append(.create(trimmed))
        }
        return result
    }

    /// Match strength against the typed string: lower sorts first. Exact match beats a
    /// prefix match beats a mid-string (substring) match; an empty query is neutral.
    private static func matchRank(_ tag: String, needle: String) -> Int {
        guard needle.isNotEmpty else { return 1 }
        if tag == needle { return 0 }
        if tag.hasPrefix(needle) { return 1 }
        return 2
    }

    /// The window within which two presses of the same arrow read as a "jump to end"
    /// rather than two single steps — the system double-click interval, so a deliberate
    /// double-press is as reachable as a double-click.
    private var doublePressInterval: TimeInterval { NSEvent.doubleClickInterval }
}

extension TagTokenField where ChipMenu == EmptyView {
    init(
        tokens: [String],
        knownTags: [String: Int],
        allowsCreate: Bool,
        placeholder: String,
        autoFocus: Bool = false,
        onAdd: @escaping (String) -> Void,
        onRemove: @escaping (String) -> Void,
        onEditingChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.init(
            tokens: tokens,
            knownTags: knownTags,
            allowsCreate: allowsCreate,
            placeholder: placeholder,
            autoFocus: autoFocus,
            onAdd: onAdd,
            onRemove: onRemove,
            onEditingChanged: onEditingChanged,
            chipMenu: { _ in EmptyView() }
        )
    }
}

/// The borderless `NSTextField` behind `TagTokenField`. It focuses itself when it
/// appears (so a click into the field starts editing), reports begin/end editing, and
/// hands the host the key commands SwiftUI fumbles on an empty field.
private struct TokenTextField: NSViewRepresentable {
    @Binding var text: String
    var onLeft: () -> Void
    var onRight: () -> Void
    var onUp: () -> Void
    var onDown: () -> Void
    var onDeleteBack: () -> Bool
    var onSubmit: () -> Void
    var onFocusChange: (Bool) -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.lineBreakMode = .byClipping
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TokenTextField

        init(_ parent: TokenTextField) { self.parent = parent }

        // MARK: Editing + text

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidBeginEditing(_ notification: Notification) { parent.onFocusChange(true) }
        func controlTextDidEndEditing(_ notification: Notification) { parent.onFocusChange(false) }

        // MARK: Caret-edge key commands

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveLeft(_:)):
                guard caretAtStart(textView) else { return false }
                parent.onLeft()
                return true
            case #selector(NSResponder.moveRight(_:)):
                guard caretAtEnd(textView) else { return false }
                parent.onRight()
                return true
            case #selector(NSResponder.moveUp(_:)):
                parent.onUp()
                return true
            case #selector(NSResponder.moveDown(_:)):
                parent.onDown()
                return true
            case #selector(NSResponder.deleteBackward(_:)):
                guard textView.string.isEmpty else { return false }
                return parent.onDeleteBack()
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                control.window?.makeFirstResponder(nil)
                return true
            default:
                return false
            }
        }

        private func caretAtStart(_ textView: NSTextView) -> Bool {
            let range = textView.selectedRange()
            return range.location == 0 && range.length == 0
        }

        private func caretAtEnd(_ textView: NSTextView) -> Bool {
            let range = textView.selectedRange()
            return range.length == 0 && range.location == (textView.string as NSString).length
        }
    }
}
