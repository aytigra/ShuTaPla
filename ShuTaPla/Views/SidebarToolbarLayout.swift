//
//  SidebarToolbarLayout.swift
//  ShuTaPla
//
//  Where the Manager's sidebar controls — the scope tabs and New Playlist — go, in both of their
//  homes. While the sidebar is open they live in a leading titlebar accessory spanning from its own
//  origin (just right of the traffic lights) to the sidebar divider, tabs flush leading and the `+`
//  on the divider; an accessory is not a toolbar item, so nothing can push a control into an
//  overflow menu there and the only way one could vanish is a width that clips it — which the two
//  geometry functions rule out. Once the sidebar collapses the container has no span left, and the
//  controls become toolbar items instead, placed *after* the sidebar tracking separator: the center
//  region, which a collapsed sidebar leaves the full window width. Pure values, `nonisolated` and
//  unit-tested.
//

import AppKit

nonisolated enum SidebarToolbarLayout {
    /// The smallest gap kept between the scope tabs and the `+`, so the two read as separate groups
    /// even when the sidebar is at its minimum.
    static let controlSpacing: CGFloat = 8

    /// What the `+` keeps clear of the sidebar divider — enough to hold its highlight off the pane's
    /// rounded corner, no more, since the divider is what the button is meant to sit on.
    static let plusTrailingInset: CGFloat = 4

    /// The narrowest a usable playlists sidebar reads at, independent of the toolbar controls. The
    /// derived thickness never goes below it, and the pane starts here before the accessory is
    /// mounted and can measure.
    static let minimumThicknessFloor: CGFloat = 200

    /// What both layouts below are resolved against: the two controls' measured fitting widths and
    /// the gaps that place them. One value rather than four arguments, since the container measures
    /// the pair once and its width and the pane's minimum thickness have to agree on them — the two
    /// are the same statement about one group, read from opposite ends.
    struct Metrics {
        var scopeWidth: CGFloat
        var plusWidth: CGFloat
        var spacing: CGFloat = SidebarToolbarLayout.controlSpacing
        var trailingInset: CGFloat = SidebarToolbarLayout.plusTrailingInset

        /// The narrowest the container can be: both controls, the gap between them, and the `+`'s
        /// inset.
        var contentWidth: CGFloat { scopeWidth + spacing + plusWidth + trailingInset }
    }

    /// The container's width and the `+`'s origin for the space the sidebar leaves —
    /// `dividerX − ownOriginX`, which sweeps down through zero as the sidebar collapses and back up
    /// as it expands. The width floors at the content, so a container that outlives its space
    /// shrinks no further than the controls themselves. The tabs sit at the container's leading
    /// edge, which the traffic lights already hold clear.
    static func resolve(
        availableWidth: CGFloat, metrics: Metrics
    ) -> (width: CGFloat, plusOrigin: CGFloat) {
        let width = max(metrics.contentWidth, availableWidth)
        return (width, width - metrics.trailingInset - metrics.plusWidth)
    }

    /// The sidebar pane's minimum thickness: the pane spans from the window's leading edge to the
    /// divider, so it has to cover the container's own inset plus the whole group. Deriving it from
    /// the controls' measured widths is what keeps a drag from ever narrowing the pane past what
    /// they need — the container then only has to squeeze on a deliberate collapse, never on a drag.
    static func minimumSidebarThickness(
        leadingInset: CGFloat, metrics: Metrics, floor: CGFloat = minimumThicknessFloor
    ) -> CGFloat {
        max(floor, leadingInset + metrics.contentWidth)
    }

    /// What the toolbar carries only while the sidebar is collapsed, and the complete difference
    /// between the two orders — so it is also the list the toolbar sync inserts and removes. The
    /// space is load-bearing: the toolbar draws one glass capsule per run of *adjacent* items, so
    /// without it the tabs and the `+` come out as a single group instead of the two separate ones
    /// the sidebar shows.
    static let collapsedOnlyIdentifiers: [NSToolbarItem.Identifier] = [.scopeTabs, .space, .newPlaylist]

    /// Breathing room between a hosted control group and the glass capsule the toolbar draws around
    /// it. That capsule hugs a custom view's bounds, and these buttons are laid out edge to edge —
    /// deliberately, since on the sidebar there is no capsule to clear — so on the toolbar line they
    /// need the inset a system item gets from its own bezel.
    static let toolbarCapsuleInset: CGFloat = 6

    /// The Manager toolbar's item order. The sidebar's own controls appear only while the sidebar is
    /// collapsed, and then directly after the tracking separator — ahead of it they would be laid
    /// out inside the sidebar region, whose budget is zero in exactly that state, and the toolbar
    /// would answer by pushing them into the overflow menu. Everything else keeps its order in both
    /// states, so the toolbar only ever has `collapsedOnlyIdentifiers` to insert or remove.
    static func toolbarIdentifiers(sidebarCollapsed: Bool) -> [NSToolbarItem.Identifier] {
        var identifiers: [NSToolbarItem.Identifier] = [.sidebarTrackingSeparator]
        if sidebarCollapsed { identifiers += collapsedOnlyIdentifiers }
        identifiers += [.title, .flexibleSpace, .centerActions]
        identifiers += [.trailingSeparator, .flexibleSpace, .manageTags, .toggleTags]
        return identifiers
    }
}
