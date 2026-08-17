//
//  ToolbarTitleBindingTests.swift
//  ShuTaPlaTests
//
//  The binding's one hard requirement: it is armed before the toolbar has built the item it writes
//  to, and it has to keep tracking its source across that gap.
//

import AppKit
import Observation
import Testing

@testable import ShuTaPla

/// A stand-in for the observable the real binding reads — `appState.managedPlaylist?.name`.
@Observable private final class Name {
    var value: String
    init(_ value: String) { self.value = value }
}

@MainActor
@Suite struct ToolbarTitleBindingTests {
    /// The ordering the app always runs: the binding is armed while `item` is still nil, and only
    /// then does the toolbar ask for the item. Both the arming and every later change have to land.
    @Test func theTitleFollowsChangesMadeAfterTheItemArrives() async throws {
        let name = Name("Porrisen")
        let binding = ToolbarTitleBinding { name.value }
        let item = NSToolbarItem(itemIdentifier: .init("ProbeTitle"))
        binding.item = item
        #expect(item.title == "Porrisen")

        name.value = "MESA"
        try await settle()
        #expect(item.title == "MESA")

        name.value = "4K"
        try await settle()
        #expect(item.title == "4K")
    }

    /// The re-arm runs on a `Task`, so a change reaches the item a turn later, not synchronously.
    private func settle() async throws {
        for _ in 0..<20 { try await Task.sleep(for: .milliseconds(10)) }
    }
}
