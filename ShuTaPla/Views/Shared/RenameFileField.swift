//
//  RenameFileField.swift
//  ShuTaPla
//
//  An inline rename field for files. On focus it selects only the base name —
//  everything before the file extension — matching Finder's rename behavior, so
//  a quick edit changes the name and leaves the extension untouched. Commits on
//  [return] or when focus is lost (a click away), cancels on [esc].
//

import SwiftUI
import AppKit

struct RenameFileField: NSViewRepresentable {
    @Binding var text: String
    var onCommit: () -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.delegate = context.coordinator
        field.bezelStyle = .roundedBezel
        field.focusRingType = .default
        field.lineBreakMode = .byTruncatingMiddle
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        // Become first responder once installed in a window, then narrow the
        // initial select-all to the base name so the extension stays out of the
        // selection (and survives an immediate retype).
        DispatchQueue.main.async {
            guard let window = field.window else { return }
            window.makeFirstResponder(field)
            context.coordinator.selectBaseName(in: field)
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: RenameFileField
        /// Set once `[return]`/`[esc]` has resolved the edit, so the end-editing that
        /// follows (the field losing first responder) doesn't fire a second outcome.
        private var resolved = false

        init(_ parent: RenameFileField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        /// Clicking away (losing focus without `[return]`/`[esc]`) commits the edit
        /// rather than stranding the field in rename mode.
        func controlTextDidEndEditing(_ notification: Notification) {
            guard !resolved else { return }
            resolved = true
            if let field = notification.object as? NSTextField { parent.text = field.stringValue }
            parent.onCommit()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                resolved = true
                parent.text = textView.string
                parent.onCommit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                resolved = true
                parent.onCancel()
                return true
            default:
                return false
            }
        }

        /// Selects the portion of the field editor's text before the extension.
        func selectBaseName(in field: NSTextField) {
            guard let editor = field.currentEditor() else { return }
            let full = field.stringValue as NSString
            let base = full.deletingPathExtension as NSString
            editor.selectedRange = NSRange(location: 0, length: min(base.length, full.length))
        }
    }
}
