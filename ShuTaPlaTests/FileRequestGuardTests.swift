//
//  FileRequestGuardTests.swift
//  ShuTaPlaTests
//
//  The guards the file-operation requests apply before they raise a confirmation or the folder
//  chooser: remove-audio eligibility (`PlaylistFile.canRemoveAudio`) and the busy refusal over
//  files with disk work in flight. The requests only set
//  `pendingConfirmation` / `folderPick`; nothing starts playback or touches the disk, so no engine
//  or folder is involved.
//

import Testing
import Foundation
import SwiftData
@testable import ShuTaPla

@MainActor
@Suite struct FileRequestGuardTests {

    private func makeContainer() throws -> ModelContainer {
        let schema = appTestSchema
        return try ModelContainer(
            for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    private func makePlaylist(_ type: MediaType, in context: ModelContext) -> Playlist {
        let playlist = Playlist(name: "P", folderBookmark: Data(), folderPath: "/tmp/p", mediaType: type)
        context.insert(playlist)
        return playlist
    }

    private func makeAppState(_ context: ModelContext) -> AppState {
        AppState(modelContext: context, fileSystem: StubFileSystem(result: emptyResult))
    }

    // MARK: - Remove-audio eligibility

    @Test(arguments: [
        (MediaType.audio, "a.mp3", false),
        (MediaType.image, "a.jpg", false),
        (MediaType.video, "a.mp4", true),   // skipped: wrong type for the playlist
    ])
    func stripRequestOnAnIneligibleFileIsANoOp(type: MediaType, name: String, skipped: Bool) throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = makePlaylist(type, in: context)
        let file = insertFile(name, skipped: skipped, order: 0, to: playlist, in: context)
        let appState = makeAppState(context)

        #expect(!appState.requestAudioStrip([file]))
        #expect(appState.pendingConfirmation == nil)
    }

    @Test func stripRequestDropsSkippedFilesFromTheSelection() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = makePlaylist(.video, in: context)
        let playable = insertFile("a.mp4", order: 0, to: playlist, in: context)
        let skipped = insertFile("b.jpg", skipped: true, order: 1, to: playlist, in: context)
        let appState = makeAppState(context)

        #expect(appState.requestAudioStrip([playable, skipped]))
        #expect(appState.pendingConfirmation?.audioStripFiles?.map(\.id) == [playable.id])
    }

    // MARK: - Busy files

    /// A file request on a file op's family, with the failure title its report carries.
    enum Request: CaseIterable {
        case delete, strip, move

        var failureTitle: String {
            switch self {
            case .delete: "Couldn't move to Trash"
            case .strip: "Couldn't remove audio"
            case .move: "Couldn't move"
            }
        }

        @MainActor func run(on appState: AppState, _ files: [PlaylistFile]) -> Bool {
            switch self {
            case .delete: appState.requestDelete(files)
            case .strip: appState.requestAudioStrip(files)
            case .move: appState.requestMove(files)
            }
        }
    }

    @Test(arguments: Request.allCases)
    func aRequestWithABusyTargetIsRefusedAndReported(_ request: Request) throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = makePlaylist(.video, in: context)
        let busy = insertFile("a.mp4", order: 0, to: playlist, in: context)
        let idle = insertFile("b.mp4", order: 1, to: playlist, in: context)
        let appState = makeAppState(context)
        appState.busyFileIDs = [busy.id]

        #expect(request.run(on: appState, [busy, idle]))

        #expect(appState.pendingConfirmation == nil)
        #expect(appState.folderPick == nil)
        #expect(appState.errorNotice == ErrorNotice(
            title: request.failureTitle,
            message: "1 file busy. Try again when their current operation is done."
        ))
    }

    @Test func aStripRequestWithOnlyABusyIneligibleFileIsASilentNoOp() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let playlist = makePlaylist(.image, in: context)
        let busy = insertFile("a.jpg", order: 0, to: playlist, in: context)
        let appState = makeAppState(context)
        appState.busyFileIDs = [busy.id]

        #expect(!appState.requestAudioStrip([busy]))

        #expect(appState.pendingConfirmation == nil)
        #expect(appState.errorNotice == nil)
    }

    // MARK: - Move pick

    @Test func completingAMoveWithNoFileLeftDoesNothingButRemembersTheFolder() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let appState = makeAppState(context)
        let folder = URL(filePath: "/tmp/dest", directoryHint: .isDirectory)
        let pruned = [UUID()]   // no row in the store
        appState.folderPick = .move(pruned)

        appState.completeFolderPick(.move(pruned), with: .success([folder]))
        for task in appState.confirmationTasks.values { await task.value }
        #expect(appState.folderPick == nil)
        #expect(appState.confirmationTasks.isEmpty)
        #expect(appState.errorNotice == nil)
        #expect(appState.lastMoveDestination == folder)
    }
}
