//
//  WindowModals.swift
//  ShuTaPla
//
//  The app-root modals of the window, one queue shown one at a time (`AppState.windowModals`).
//

import Foundation

/// A modal the app root presents over the window.
enum WindowModal {
    case confirmation(PendingConfirmation)
    case report(ErrorNotice)
    case typeChoice(ScannedFolder)
    case folderPick(FolderPick)
    case quitWait

    enum Kind {
        case confirmation, report, typeChoice, folderPick, quitWait

        /// Whether the modal takes bare keys itself, so `HotkeyRouter` passes them through while it
        /// shows: an out-of-process system panel does; an in-process `.alert` relies on the router.
        var ownsKeys: Bool {
            switch self {
            case .folderPick: true
            case .confirmation, .report, .typeChoice, .quitWait: false
            }
        }
    }

    var kind: Kind {
        switch self {
        case .confirmation: .confirmation
        case .report: .report
        case .typeChoice: .typeChoice
        case .folderPick: .folderPick
        case .quitWait: .quitWait
        }
    }

    var confirmation: PendingConfirmation? {
        if case .confirmation(let pending) = self { pending } else { nil }
    }

    var report: ErrorNotice? {
        if case .report(let notice) = self { notice } else { nil }
    }

    var typeChoice: ScannedFolder? {
        if case .typeChoice(let folder) = self { folder } else { nil }
    }

    var folderPick: FolderPick? {
        if case .folderPick(let pick) = self { pick } else { nil }
    }
}

/// The window's modals in show order. Only the head is presented, so two never present at once:
/// SwiftUI drops one of them. The head shows once the window has no sheet (`AppState.windowHasSheet`).
struct WindowModals {
    private(set) var queue: [WindowModal] = []

    /// Whether the head is on screen. Removing it clears the mark: the next one waits for the
    /// closing sheet to end.
    private(set) var isHeadShown = false

    /// The modal on screen.
    var shown: WindowModal? { isHeadShown ? queue.first : nil }

    var isNotEmpty: Bool { queue.isNotEmpty }

    /// Whether `showHead()` has a head to show.
    var canShowHead: Bool { !isHeadShown && queue.isNotEmpty }

    mutating func showHead() {
        isHeadShown = queue.isNotEmpty
    }

    /// Queues `modal` behind the others and ahead of the quit wait, which only waits on work and
    /// stays last. A modal raised while the quit wait shows takes its place; the wait shows after it.
    mutating func raise(_ modal: WindowModal) {
        guard modal.kind != .quitWait, let wait = queue.firstIndex(where: { $0.kind == .quitWait }) else {
            queue.append(modal)
            return
        }
        if wait == 0 { isHeadShown = false }
        queue.insert(modal, at: wait)
    }

    /// Sets the one modal of `kind`: replaces it in place, removes it (`nil`), or raises it. For the
    /// kinds that hold at most one modal, every kind but `.report`.
    mutating func set(_ kind: WindowModal.Kind, to modal: WindowModal?) {
        guard let index = queue.firstIndex(where: { $0.kind == kind }) else {
            if let modal { raise(modal) }
            return
        }
        if let modal {
            queue[index] = modal
        } else {
            remove(at: index)
        }
    }

    /// Removes the shown modal when it is of `kind`.
    mutating func removeShown(_ kind: WindowModal.Kind) {
        guard shown?.kind == kind else { return }
        remove(at: 0)
    }

    private mutating func remove(at index: Int) {
        queue.remove(at: index)
        if index == 0 { isHeadShown = false }
    }
}
