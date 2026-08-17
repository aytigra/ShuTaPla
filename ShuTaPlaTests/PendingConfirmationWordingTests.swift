//
//  PendingConfirmationWordingTests.swift
//  ShuTaPlaTests
//
//  The wording of the destructive confirmations. One alert host reads these three properties, so
//  they are the whole user-facing text of every confirmation in the app — and the only place a
//  family's phrasing can be pinned. The count-sensitive titles matter most: the singular indexes
//  the payload, so an empty or plural payload must never reach it.
//

import Testing
import Foundation
import SwiftData
@testable import ShuTaPla

@MainActor
struct PendingConfirmationWordingTests {

    private func file(_ name: String) -> PlaylistFile {
        PlaylistFile(relativePath: name, fileName: name, sortOrder: 0)
    }

    private func playlist(_ name: String) -> Playlist {
        Playlist(name: name, folderBookmark: Data(), folderPath: "/p", mediaType: .video)
    }

    // MARK: - Titles

    @Test func aSingleFileIsNamedAndSeveralAreCounted() {
        #expect(PendingConfirmation.managerDelete([file("a.mp4")]).title == "Move “a.mp4” to the Trash?")
        #expect(PendingConfirmation.managerDelete([file("a.mp4"), file("b.mp4")]).title == "Move 2 files to the Trash?")

        #expect(PendingConfirmation.audioStrip([file("a.mp4")]).title == "Remove the audio from “a.mp4”?")
        #expect(PendingConfirmation.audioStrip([file("a.mp4"), file("b.mp4")]).title == "Remove the audio from 2 files?")
    }

    /// The host evaluates the wording for whatever is pending, and a request can be pruned down to
    /// nothing by a re-scan; the plural branch must not index the payload.
    @Test func anEmptyPayloadCountsRatherThanIndexing() {
        #expect(PendingConfirmation.managerDelete([]).title == "Move 0 files to the Trash?")
        #expect(PendingConfirmation.audioStrip([]).title == "Remove the audio from 0 files?")
    }

    @Test func thePlayerAndAudioDeletesWordTheSameAsASingleManagerDelete() {
        let track = file("song.mp3")
        #expect(PendingConfirmation.playerDelete(track).title == "Move “song.mp3” to the Trash?")
        #expect(PendingConfirmation.audioDelete(track).title == "Move “song.mp3” to the Trash?")
        #expect(PendingConfirmation.playerDelete(track).message == PendingConfirmation.managerDelete([track]).message)
    }

    @Test func theRemainingTitlesNameTheirTarget() {
        #expect(PendingConfirmation.tagRemoval("beach").title == "Remove “beach” from every file in this playlist?")
        #expect(PendingConfirmation.playlistDelete(playlist("Trips")).title == "Delete the playlist “Trips”?")

        let search = SavedSearch(name: "Sunny")
        #expect(PendingConfirmation.savedSearchDelete(search).title == "Delete the saved search “Sunny”?")
    }

    // MARK: - Messages and buttons

    @Test func aDeleteMessageAgreesWithItsCount() {
        #expect(PendingConfirmation.managerDelete([file("a.mp4")]).message.hasPrefix("The file is"))
        #expect(PendingConfirmation.managerDelete([file("a.mp4"), file("b.mp4")]).message.hasPrefix("The files are"))
    }

    /// Every confirmation says what it costs — none of them leans on the title alone.
    @Test func everyFamilyCarriesAMessage() {
        for pending in allFamilies() {
            #expect(pending.message.isNotEmpty)
        }
    }

    /// The destructive button names the act, so the choice reads without the title.
    @Test func theConfirmButtonNamesTheAct() {
        #expect(PendingConfirmation.managerDelete([file("a.mp4")]).confirmLabel == "Move to Trash")
        #expect(PendingConfirmation.playerDelete(file("a.mp4")).confirmLabel == "Move to Trash")
        #expect(PendingConfirmation.audioDelete(file("a.mp3")).confirmLabel == "Move to Trash")
        #expect(PendingConfirmation.audioStrip([file("a.mp4")]).confirmLabel == "Remove Audio")
        #expect(PendingConfirmation.tagRemoval("beach").confirmLabel == "Remove Tag")
        #expect(PendingConfirmation.playlistDelete(playlist("Trips")).confirmLabel == "Delete")
        #expect(PendingConfirmation.savedSearchDelete(SavedSearch(name: "Sunny")).confirmLabel == "Delete")
    }

    /// One of each case, so the sweep above covers every family.
    private func allFamilies() -> [PendingConfirmation] {
        [
            .managerDelete([file("a.mp4")]),
            .playerDelete(file("a.mp4")),
            .audioDelete(file("a.mp3")),
            .audioStrip([file("a.mp4")]),
            .tagRemoval("beach"),
            .playlistDelete(playlist("Trips")),
            .savedSearchDelete(SavedSearch(name: "Sunny"))
        ]
    }
}
