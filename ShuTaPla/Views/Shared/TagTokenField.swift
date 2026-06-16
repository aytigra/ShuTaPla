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
//  commands come straight from AppKit: it reports begin/end editing, routes
//  `delete`/arrows/`return`/`esc` only at the caret edges, and — while focused —
//  watches for a mouse-down outside the control (the field, its chips, or the open
//  dropdown) to give up focus, so clicking any other control or a playlist closes it
//  without swallowing that click.
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
    let onAdd: (String) -> Void
    let onRemove: (String) -> Void
    @ViewBuilder let chipMenu: (String) -> ChipMenu

    @State private var input = ""
    @State private var highlighted = 0
    @State private var selectedChip: Int?
    @State private var editing = false
    @State private var controlFrame: CGRect = .zero
    @State private var inputFrame: CGRect = .zero
    @State private var lastLeft: Date?
    @State private var lastRight: Date?

    private let rowHeight: CGFloat = 30

    var body: some View {
        field
            // Integer bounds so successive sub-pixel measurements settle rather than
            // cycling (which SwiftUI faults on).
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global).integral } action: { controlFrame = $0 }
            .overlay(alignment: .topLeading) {
                if editing, !options.isEmpty {
                    dropdown.offset(y: controlFrame.height + 4)
                }
            }
            // While the dropdown is open the field floats above the controls below it.
            .zIndex(editing ? 1 : 0)
    }

    // MARK: - Field

    private var field: some View {
        FlowLayout {
            ForEach(Array(tokens.enumerated()), id: \.offset) { index, tag in
                chip(tag, index: index)
            }
            inputSlot
        }
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
                insideRects: [controlFrame, dropdownRect],
                selfFrame: inputFrame,
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
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global).integral } action: { inputFrame = $0 }
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
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Color.accentColor.opacity(selectedChip == index ? 0.4 : 0.18),
            in: Capsule()
        )
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

    /// The dropdown's on-screen rect, derived from the field's frame and the render
    /// offset below it. (Computed rather than measured: `.offset` shifts the rendering
    /// but not the layout frame, so a measured `.global` frame would point at the
    /// field, not where the dropdown actually appears.)
    private var dropdownRect: CGRect {
        guard editing, !options.isEmpty, !controlFrame.isEmpty else { return .zero }
        let height = CGFloat(min(options.count, 6)) * rowHeight
        return CGRect(x: controlFrame.minX, y: controlFrame.maxY + 4, width: controlFrame.width, height: height)
    }

    private var dropdown: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                    optionRow(option, index: index)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: CGFloat(min(options.count, 6)) * rowHeight)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
        .shadow(radius: 8, y: 2)
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
            .frame(height: rowHeight)
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
    }

    private func endEditing() {
        editing = false
        input = ""
        selectedChip = nil
        highlighted = 0
    }

    // MARK: - Caret / chip navigation (only fired at the input's caret edges)

    private func moveCaretLeft() {
        guard !tokens.isEmpty else { return }
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
            if !tokens.isEmpty { selectedChip = tokens.count - 1 }
            return
        }
        guard let chip = selectedChip else { return }
        selectedChip = chip >= tokens.count - 1 ? nil : chip + 1
    }

    private func moveHighlightUp() {
        guard !options.isEmpty else { return }
        highlighted = max(0, highlighted - 1)
    }

    private func moveHighlightDown() {
        guard !options.isEmpty else { return }
        highlighted = min(options.count - 1, highlighted + 1)
    }

    /// Removes the chip at the caret (the selected one, or the last). Returns whether a
    /// chip was removed, so the input only swallows `delete` when it acts on a chip.
    private func deleteAtCaret() -> Bool {
        guard !tokens.isEmpty else { return false }
        let target = selectedChip ?? tokens.count - 1
        selectedChip = target > 0 ? target - 1 : nil
        onRemove(tokens[target])
        return true
    }

    // MARK: - Commit

    private func commit() {
        let current = options
        if !current.isEmpty, highlighted < current.count {
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
        guard !needle.isEmpty else { return 1 }
        if tag == needle { return 0 }
        if tag.hasPrefix(needle) { return 1 }
        return 2
    }

    /// The window within which two presses of the same arrow read as a "jump to end"
    /// rather than two single steps.
    private var doublePressInterval: TimeInterval { 0.09 }
}

extension TagTokenField where ChipMenu == EmptyView {
    init(
        tokens: [String],
        knownTags: [String: Int],
        allowsCreate: Bool,
        placeholder: String,
        onAdd: @escaping (String) -> Void,
        onRemove: @escaping (String) -> Void
    ) {
        self.init(
            tokens: tokens,
            knownTags: knownTags,
            allowsCreate: allowsCreate,
            placeholder: placeholder,
            onAdd: onAdd,
            onRemove: onRemove,
            chipMenu: { _ in EmptyView() }
        )
    }
}

/// The borderless `NSTextField` behind `TagTokenField`. It focuses itself when it
/// appears (so a click into the field starts editing), reports begin/end editing, and
/// hands the host the key commands SwiftUI fumbles on an empty field. While focused it
/// also runs a local mouse-down monitor: a click outside `insideRects` (the control
/// and its open dropdown, in SwiftUI global coordinates) resigns focus without
/// consuming the click, so a single click elsewhere both closes the field and lands.
private struct TokenTextField: NSViewRepresentable {
    @Binding var text: String
    var insideRects: [CGRect]
    var selfFrame: CGRect
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
        context.coordinator.startOutsideMonitor(for: field)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    static func dismantleNSView(_ nsView: NSTextField, coordinator: Coordinator) {
        coordinator.stopOutsideMonitor()
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TokenTextField
        private var monitor: Any?

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

        // MARK: Outside-click monitor

        func startOutsideMonitor(for field: NSTextField) {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self, weak field] event in
                guard let self, let field, let window = field.window, event.window === window else { return event }
                if !self.clickIsInsideControl(event, field: field) {
                    window.makeFirstResponder(nil)
                }
                return event
            }
        }

        func stopOutsideMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        /// Maps the click into SwiftUI global coordinates via the input's own two
        /// frames (its AppKit window rect and its measured global rect give the
        /// translation + y-flip between the spaces), then tests it against the control
        /// and dropdown rects.
        private func clickIsInsideControl(_ event: NSEvent, field: NSTextField) -> Bool {
            let appKit = field.convert(field.bounds, to: nil)   // window coords, y-up
            let swiftUI = parent.selfFrame                       // global coords, y-down
            guard appKit.height > 0, swiftUI.height > 0 else { return true }

            let click = event.locationInWindow
            let global = CGPoint(
                x: swiftUI.minX + (click.x - appKit.minX),
                y: swiftUI.minY + (appKit.maxY - click.y)
            )
            return parent.insideRects.contains { !$0.isEmpty && $0.contains(global) }
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
