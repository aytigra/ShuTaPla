//
//  ToolbarTitleBinding.swift
//  ShuTaPla
//
//  Keeps a toolbar item's title on an observable source.
//
//  Its own type rather than a few lines inside the toolbar delegate, because the ordering it has to
//  survive is not obvious: a toolbar builds its items lazily, well after the controller that owns
//  them loads, so the binding is always armed while there is no item yet. That is the case the
//  naive form gets silently wrong — see `apply()`.
//

import AppKit
import Observation

@MainActor
final class ToolbarTitleBinding {
    /// The item to keep titled, once the toolbar has built it. Weak: the toolbar owns its items and
    /// drops them when it detaches, and a binding that outlives a toolbar must not hold one alive.
    weak var item: NSToolbarItem? {
        didSet { apply() }
    }

    private let read: @MainActor () -> String

    init(read: @escaping @MainActor () -> String) {
        self.read = read
        observe()
    }

    /// `withObservationTracking` fires once, so every change re-arms it.
    private func observe() {
        withObservationTracking {
            apply()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    /// Reads first and assigns second, deliberately. `item?.title = read()` looks equivalent and is
    /// not: optional chaining skips its right-hand side entirely when the item is nil, so arming
    /// with no item yet — which is every arming — would read nothing, therefore track nothing, and
    /// the binding would never fire again.
    private func apply() {
        let title = read()
        item?.title = title
    }
}
