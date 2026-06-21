//
//  OverlayManagerTests.swift
//  ShuTaPlaTests
//
//  Exercises the overlay exclusivity rules and the audio key-context gating. Pure
//  state-machine tests: no SwiftData container and no libmpv engine, so none of the
//  test-host trap classes apply.
//

import Testing
@testable import ShuTaPla

@MainActor
@Suite struct OverlayManagerTests {

    // MARK: - Exclusivity

    @Test func audioExtendedClosesFilesTagsAndPlaylists() {
        let m = OverlayManager()
        m.show(.filesTags)
        m.show(.playlistsSidebar)   // suppressed while filesTags open, but assert regardless
        m.show(.audioExtended)
        #expect(!m.active.contains(.filesTags))
        #expect(!m.active.contains(.playlistsSidebar))
        #expect(m.active.contains(.audioExtended))
    }

    @Test func filesTagsClosesCompactAudioAndBottomControls() {
        let m = OverlayManager()
        m.show(.audioCompact)
        m.show(.bottomControls)
        m.show(.filesTags)
        #expect(!m.active.contains(.audioCompact))
        #expect(!m.active.contains(.bottomControls))
        #expect(m.active.contains(.filesTags))
    }

    @Test func pauseOverlayClosesEverythingElse() {
        let m = OverlayManager()
        m.show(.filesTags)
        m.show(.audioCompact)
        m.show(.pauseOverlay)
        #expect(m.active == [.pauseOverlay])
    }

    @Test func compactAudioSitsOnTopOfFilesTags() {
        let m = OverlayManager()
        m.show(.filesTags)
        m.show(.audioCompact)
        #expect(m.active.contains(.filesTags))
        #expect(m.active.contains(.audioCompact))
    }

    @Test func hoverOverlaysSuppressedWhileFilesTagsOpen() {
        let m = OverlayManager()
        m.show(.filesTags)
        m.show(.playlistsSidebar)
        m.show(.bottomControls)
        #expect(!m.active.contains(.playlistsSidebar))
        #expect(!m.active.contains(.bottomControls))
    }

    @Test func hoverOverlaysSuppressedWhileAudioExtendedOpen() {
        let m = OverlayManager()
        m.show(.audioExtended)
        m.show(.playlistsSidebar)
        m.show(.bottomControls)
        #expect(!m.active.contains(.playlistsSidebar))
        #expect(!m.active.contains(.bottomControls))
    }

    // MARK: - Esc chain helpers

    @Test func isAnyOverlayOpenReflectsClosableOverlaysOnly() {
        let m = OverlayManager()
        #expect(!m.isAnyOverlayOpen)
        m.show(.bottomControls)          // passive hover chrome — not a closable overlay
        #expect(!m.isAnyOverlayOpen)
        m.show(.playlistsSidebar)
        #expect(m.isAnyOverlayOpen)
    }

    @Test func closeTopmostFollowsPriorityOrder() {
        let m = OverlayManager()
        m.show(.playlistsSidebar)
        m.show(.audioCompact)
        m.closeTopmostOverlay()          // audioCompact outranks playlistsSidebar
        #expect(!m.active.contains(.audioCompact))
        #expect(m.active.contains(.playlistsSidebar))
        m.closeTopmostOverlay()
        #expect(!m.active.contains(.playlistsSidebar))
    }

    // MARK: - Audio key context

    @Test func audioKeyContextRequiresRevealAndActiveOverlay() {
        let m = OverlayManager()
        m.revealCompactAudio()
        #expect(!m.audioHoldsKeyContext)         // shown but not yet fully revealed
        m.audioDidFullyReveal()
        #expect(m.audioHoldsKeyContext)
    }

    @Test func audioKeyContextClearsWhenOverlayCloses() {
        let m = OverlayManager()
        m.revealCompactAudio()
        m.audioDidFullyReveal()
        #expect(m.audioHoldsKeyContext)
        m.closeAudioOverlay()
        #expect(!m.audioHoldsKeyContext)
        #expect(!m.active.contains(.audioCompact))
        #expect(!m.active.contains(.audioExtended))
    }

    @Test func audioKeyContextClearsWhenFilesTagsClosesCompactAudio() {
        let m = OverlayManager()
        m.revealCompactAudio()
        m.audioDidFullyReveal()
        m.show(.filesTags)                        // exclusivity removes audioCompact
        #expect(!m.audioHoldsKeyContext)
    }

    // MARK: - Compact audio: hover vs. hotkey

    @Test func hoverRevealedCompactClosesOnHoverExit() {
        let m = OverlayManager()
        m.revealCompactAudioOnHover()
        #expect(m.active.contains(.audioCompact))
        m.hideCompactAudioOnHoverExit()                  // cursor leaves → auto-close
        #expect(!m.active.contains(.audioCompact))
    }

    @Test func hotkeyRevealedCompactStaysOnHoverExit() {
        let m = OverlayManager()
        m.revealCompactAudio()                           // [arrow down] — pinned open
        #expect(m.active.contains(.audioCompact))
        m.hideCompactAudioOnHoverExit()                  // a stray hover-exit must not close it
        #expect(m.active.contains(.audioCompact))
    }

    @Test func hoverRevealIsANoOpWhileExtendedOpen() {
        let m = OverlayManager()
        m.expandAudioToExtended()
        m.revealCompactAudioOnHover()                    // must not disturb the extended overlay
        #expect(m.active.contains(.audioExtended))
        #expect(!m.active.contains(.audioCompact))
    }

    @Test func expandToExtendedKeepsKeyContext() {
        let m = OverlayManager()
        m.revealCompactAudio()
        m.audioDidFullyReveal()
        m.expandAudioToExtended()                 // audioCompact → audioExtended, both are audio
        #expect(m.active.contains(.audioExtended))
        #expect(m.audioHoldsKeyContext)
    }

    @Test func collapseToCompactReturnsToCompactAndKeepsKeyContext() {
        let m = OverlayManager()
        m.revealCompactAudio()
        m.audioDidFullyReveal()
        m.expandAudioToExtended()
        m.collapseAudioToCompact()                // audioExtended → audioCompact, still audio
        #expect(m.active.contains(.audioCompact))
        #expect(!m.active.contains(.audioExtended))
        #expect(m.audioHoldsKeyContext)
    }

    // The collapsed bar stays pinned, so a stray hover-exit after collapsing doesn't close it.
    @Test func collapseToCompactPinsTheBar() {
        let m = OverlayManager()
        m.expandAudioToExtended()
        m.collapseAudioToCompact()
        m.hideCompactAudioOnHoverExit()
        #expect(m.active.contains(.audioCompact))
    }
}
