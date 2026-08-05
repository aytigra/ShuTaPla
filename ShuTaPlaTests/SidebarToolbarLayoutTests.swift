//
//  SidebarToolbarLayoutTests.swift
//  ShuTaPlaTests
//
//  The Manager's sidebar controls have two homes, and these tests pin both. While the sidebar is
//  open they sit in a leading titlebar accessory sized to the sidebar divider: what the layout tests
//  refute is that either control can be clipped or pushed outside the container at any sidebar
//  width — the failure the toolbar's overflow layout produces today. Once the sidebar collapses they
//  become toolbar items, and the identifier tests pin them *after* the sidebar tracking separator,
//  since sitting before it — inside a region whose budget is zero exactly when the sidebar is
//  collapsed — is what pushed them into overflow in the first place.
//

import Testing
import AppKit
@testable import ShuTaPla

@Suite struct SidebarToolbarLayoutTests {

    // Stand-ins for the controls' measured fitting widths. The layout takes them as inputs rather
    // than baking them in, so it stays correct when the real controls change size.
    let scope: CGFloat = 100
    let plus: CGFloat = 32
    let gap: CGFloat = 8

    /// Deliberately neither zero nor the production 4, so an inset dropped or hardcoded reads as a
    /// wrong origin instead of coinciding with the right one.
    let inset: CGFloat = 6

    /// The narrowest the container can ever be: both controls, the gap between them, and the `+`'s
    /// inset from the divider.
    func minimumContent(_ trailingInset: CGFloat) -> CGFloat {
        scope + gap + plus + trailingInset
    }

    func metrics(_ trailingInset: CGFloat) -> SidebarToolbarLayout.Metrics {
        .init(scopeWidth: scope, plusWidth: plus, spacing: gap, trailingInset: trailingInset)
    }

    func resolve(_ availableWidth: CGFloat, _ trailingInset: CGFloat) -> (width: CGFloat, plusOrigin: CGFloat) {
        SidebarToolbarLayout.resolve(availableWidth: availableWidth, metrics: metrics(trailingInset))
    }

    func minimumThickness(leadingInset: CGFloat, _ trailingInset: CGFloat) -> CGFloat {
        SidebarToolbarLayout.minimumSidebarThickness(
            leadingInset: leadingInset, metrics: metrics(trailingInset), floor: 200
        )
    }

    // MARK: - resolve

    @Test func wideSidebarFillsTheAvailableWidthAndPinsPlusToTheDivider() {
        let layout = resolve(400, inset)
        #expect(layout.width == 400)
        #expect(layout.plusOrigin == 400 - inset - plus)
    }

    @Test func atTheDerivedMinimumThicknessEverythingFitsWithoutOverhang() {
        // The sidebar can't be dragged narrower than this, so it is the tightest real layout: the
        // width the pane leaves is exactly the minimum content, the `+` still lands its inset short
        // of the divider, and the tabs end no later than where the `+` begins.
        let thickness = minimumThickness(leadingInset: 88, inset)
        let layout = resolve(thickness - 88, inset)
        #expect(layout.width == minimumContent(inset))
        #expect(layout.plusOrigin == layout.width - inset - plus)
        #expect(scope <= layout.plusOrigin)
    }

    @Test(arguments: [CGFloat(0), -1, -400])
    func aVanishingWidthKeepsTheMinimumContent(_ available: CGFloat) {
        // The width the sidebar leaves sweeps down through zero during a collapse and back up during
        // an expand. The container stops shrinking at its content instead of clipping a control away.
        let layout = resolve(available, inset)
        #expect(layout.width == minimumContent(inset))
        #expect(layout.plusOrigin == layout.width - inset - plus)
    }

    // MARK: - The `+`'s inset

    @Test func thePlusStopsShortOfTheDivider() {
        // Stated as a difference against a flush layout, so it pins what the inset *does* rather than
        // restating the arithmetic: the `+` moves in from the divider by exactly the inset, and the
        // container's width doesn't change with it.
        let flush = resolve(400, 0)
        let held = resolve(400, inset)
        #expect(held.width == flush.width)
        #expect(flush.plusOrigin - held.plusOrigin == inset)
    }

    // MARK: - minimumSidebarThickness

    @Test func minimumThicknessCoversTheLeadingInsetPlusTheWholeGroup() {
        #expect(minimumThickness(leadingInset: 88, inset) == 88 + minimumContent(inset))  // 234
    }

    @Test func minimumThicknessNeverDropsBelowTheFloor() {
        // Controls small enough to fit inside the floor don't let the pane shrink past it.
        let thickness = SidebarToolbarLayout.minimumSidebarThickness(
            leadingInset: 88,
            metrics: .init(scopeWidth: 20, plusWidth: 20, spacing: 4, trailingInset: inset),
            floor: 200
        )
        #expect(thickness == 200)
    }

    // MARK: - Sweep

    @Test(
        arguments: [CGFloat(-500), -1, 0, 1, 50, 139, 140, 141, 300, 2000],
        [CGFloat(0), 4, 6]
    )
    func noWidthEverClipsOrEjectsAControl(_ available: CGFloat, _ trailingInset: CGFloat) {
        let layout = resolve(available, trailingInset)
        #expect(layout.width >= minimumContent(trailingInset))
        #expect(scope <= layout.plusOrigin)
        #expect(layout.plusOrigin + plus + trailingInset <= layout.width)
    }

    @Test(arguments: [CGFloat(0), 24, 88, 200], [CGFloat(0), 4, 6])
    func aPaneAtTheMinimumThicknessAlwaysFitsTheGroup(_ leading: CGFloat, _ trailingInset: CGFloat) {
        // Ties the two functions together: whatever the traffic-light inset, a sidebar at the
        // derived minimum leaves the container at least its content width.
        let thickness = minimumThickness(leadingInset: leading, trailingInset)
        #expect(thickness >= leading + minimumContent(trailingInset))
        #expect(resolve(thickness - leading, trailingInset).width >= minimumContent(trailingInset))
    }
}

/// The other home: the toolbar's item order, which is where the two controls live once the sidebar
/// is collapsed and the accessory has stepped out of the titlebar.
@Suite struct ManagerToolbarIdentifierTests {

    func identifiers(sidebarCollapsed: Bool) -> [NSToolbarItem.Identifier] {
        SidebarToolbarLayout.toolbarIdentifiers(sidebarCollapsed: sidebarCollapsed)
    }

    @Test func anOpenSidebarKeepsItsControlsOutOfTheToolbar() {
        // They belong to the sidebar itself then, drawn by the titlebar accessory.
        let open = identifiers(sidebarCollapsed: false)
        #expect(!open.contains(.scopeTabs))
        #expect(!open.contains(.newPlaylist))
    }

    @Test func aCollapsedSidebarPutsBothControlsDirectlyAfterTheTrackingSeparator() throws {
        // After the separator they are in the center region, which a collapsed sidebar leaves the
        // full window width — so nothing can push them into the overflow menu.
        let collapsed = identifiers(sidebarCollapsed: true)
        let separator = try #require(collapsed.firstIndex(of: .sidebarTrackingSeparator))
        let scope = try #require(collapsed.firstIndex(of: .scopeTabs))
        let plus = try #require(collapsed.firstIndex(of: .newPlaylist))
        #expect(scope == separator + 1)
        #expect(plus < collapsed.firstIndex(of: .title) ?? 0)
    }

    @Test func aFixedSpaceSeparatesTheTwoControlsSoTheToolbarDrawsTwoCapsules() throws {
        // The toolbar draws one glass capsule per run of adjacent items, so two controls left
        // touching read as a single group. A fixed `.space` between them is what makes the scope
        // tabs and the `+` two groups, adjacent but separated, as they are on the sidebar — a
        // `.flexibleSpace` would separate them too, by flinging the `+` to the toolbar's far end.
        let collapsed = identifiers(sidebarCollapsed: true)
        let scope = try #require(collapsed.firstIndex(of: .scopeTabs))
        let plus = try #require(collapsed.firstIndex(of: .newPlaylist))
        #expect(Array(collapsed[(scope + 1)..<plus]) == [.space])
    }

    @Test(arguments: [false, true])
    func neitherControlEverPrecedesTheTrackingSeparator(_ sidebarCollapsed: Bool) {
        // The bug itself: ahead of the separator they are laid out inside the sidebar region's
        // budget, which is exactly what collapsing takes to zero.
        let items = identifiers(sidebarCollapsed: sidebarCollapsed)
        let separator = items.firstIndex(of: .sidebarTrackingSeparator) ?? items.count
        let leading = Array(items[..<separator])
        #expect(!leading.contains(.scopeTabs))
        #expect(!leading.contains(.newPlaylist))
    }

    @Test func collapsingAddsTheSidebarsOwnItemsAndNothingElseMoves() {
        // What the toolbar sync relies on: the collapsed-only items are the complete difference
        // between the two orders. The rest — title, center actions, the trailing separator, the tag
        // controls — keeps its order across the switch, so the sync never has to touch it.
        let open = identifiers(sidebarCollapsed: false)
        let collapsed = identifiers(sidebarCollapsed: true)
        let moved = SidebarToolbarLayout.collapsedOnlyIdentifiers
        #expect(collapsed.count == open.count + moved.count)
        var rest = collapsed
        for identifier in moved {
            if let index = rest.firstIndex(of: identifier) { rest.remove(at: index) }
        }
        #expect(rest == open)
    }

    @Test func theOpenOrderHoldsNoneOfTheCollapsedOnlyItems() {
        let open = identifiers(sidebarCollapsed: false)
        for identifier in SidebarToolbarLayout.collapsedOnlyIdentifiers {
            #expect(!open.contains(identifier))
        }
    }
}

/// The controls' other pure seam: which highlight capsule one of them draws for the state it is in.
@Suite struct TitlebarControlHighlightTests {

    func fill(
        isActive: Bool = false, isPressed: Bool = false, hovering: Bool = false, isEnabled: Bool = true
    ) -> Double {
        TitlebarControlButtonStyle.fillOpacity(
            isActive: isActive, isPressed: isPressed, hovering: hovering, isEnabled: isEnabled
        )
    }

    @Test func anIdleControlDrawsNoCapsule() {
        #expect(fill() == 0)
    }

    @Test func thePointerDrawsASofterCapsuleThanTheActiveState() {
        #expect(fill(hovering: true) > 0)
        #expect(fill(hovering: true) < fill(isActive: true))
    }

    @Test(arguments: [(true, false), (false, true), (true, true)])
    func anActiveOrPressedControlDrawsTheFullCapsule(_ isActive: Bool, _ isPressed: Bool) {
        #expect(fill(isActive: isActive, isPressed: isPressed) == 1)
    }

    @Test func aDisabledControlUnderThePointerDrawsNoCapsule() {
        // The state the `+` reaches when a folder import disables it with the pointer already on it:
        // whether the capsule shows has to be decided as it is drawn, since nothing delivers a hover
        // event on the enablement change itself.
        #expect(fill(hovering: true, isEnabled: false) == 0)
    }
}
