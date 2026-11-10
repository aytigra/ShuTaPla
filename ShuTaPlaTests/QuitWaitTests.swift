//
//  QuitWaitTests.swift
//  ShuTaPlaTests
//
//  A quit while files are under disk work is held until they are done, then answered `true`;
//  Cancel answers `false`.
//

import AppKit
import Foundation
import SwiftData
import Testing
@testable import ShuTaPla

@MainActor
struct QuitWaitTests {

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: appTestSchema, configurations: [ModelConfiguration(schema: appTestSchema, isStoredInMemoryOnly: true)]
        )
    }

    /// An `AppState` whose replies to a held quit are recorded, not sent.
    private func makeAppState(_ container: ModelContainer) -> (AppState, Replies) {
        let appState = AppState(modelContext: container.mainContext, makeVideoEngine: { try AudioPlaybackEngine() })
        let replies = Replies()
        appState.replyToTerminate = { replies.values.append($0) }
        return (appState, replies)
    }

    /// Starts the delete of a new empty playlist and holds it on the playlist's background task
    /// until the returned scan opens.
    private func startHeldDelete(_ appState: AppState, in context: ModelContext) async throws -> (HeldScan, Task<Void, Never>) {
        let playlist = Playlist(name: "Q", folderBookmark: Data(), folderPath: "/tmp/q", mediaType: .image)
        context.insert(playlist)
        try context.save()
        let scan = HeldScan(on: playlist, appState)
        let deletion = Task { await appState.delete(playlist) }
        try await waitUntil { appState.playlistWork.isDeleting(playlist.id) }
        return (scan, deletion)
    }

    /// Lets the main-actor task that answers the held quit run.
    private func drainMainActor() async {
        for _ in 0..<20 { await Task.yield() }
    }

    @Test func anIdleAppQuitsAtOnce() throws {
        let container = try makeContainer()
        let (appState, _) = makeAppState(container)

        #expect(appState.shouldTerminate() == .terminateNow)
        #expect(!appState.isWaitingToQuit)
    }

    @Test func aBusyAppHoldsTheQuitWithoutAReply() async throws {
        let container = try makeContainer()
        let (appState, replies) = makeAppState(container)
        appState.busyFileIDs = [UUID()]

        #expect(appState.shouldTerminate() == .terminateLater)
        await drainMainActor()

        #expect(appState.isWaitingToQuit)
        #expect(replies.values.isEmpty)
    }

    @Test func theWaitQuitsWhenTheLastBusyFileIsReleased() async throws {
        let container = try makeContainer()
        let (appState, replies) = makeAppState(container)
        let (a, b) = (UUID(), UUID())
        appState.busyFileIDs = [a, b]
        _ = appState.shouldTerminate()

        appState.busyFileIDs.remove(a)
        await drainMainActor()
        #expect(replies.values.isEmpty)

        appState.busyFileIDs.remove(b)
        await drainMainActor()
        #expect(replies.values == [true])
        #expect(!appState.isWaitingToQuit)
    }

    /// Work that starts between the last release and the reply (a Task queued before the reply)
    /// holds the quit until it ends.
    @Test func workThatStartsBeforeTheReplyHoldsTheQuit() async throws {
        let container = try makeContainer()
        let (appState, replies) = makeAppState(container)
        appState.busyFileIDs = [UUID()]
        _ = appState.shouldTerminate()

        appState.busyFileIDs = []
        appState.busyFileIDs = [UUID()]
        await drainMainActor()
        #expect(replies.values.isEmpty)
        #expect(appState.isWaitingToQuit)

        appState.busyFileIDs = []
        await drainMainActor()
        #expect(replies.values == [true])
    }

    /// The alert's button and its dismissal both cancel: the held quit gets one reply.
    @Test func cancelRefusesTheHeldQuitOnce() async throws {
        let container = try makeContainer()
        let (appState, replies) = makeAppState(container)
        appState.busyFileIDs = [UUID()]
        _ = appState.shouldTerminate()

        appState.cancelQuit()
        appState.cancelQuit()
        appState.busyFileIDs = []
        await drainMainActor()

        #expect(!appState.isWaitingToQuit)
        #expect(replies.values == [false])
    }

    @Test func cancelAfterTheLastReleaseStillPreventsTheQuit() async throws {
        let container = try makeContainer()
        let (appState, replies) = makeAppState(container)
        appState.busyFileIDs = [UUID()]
        _ = appState.shouldTerminate()

        appState.busyFileIDs = []
        appState.cancelQuit()
        await drainMainActor()

        #expect(replies.values == [false])
    }

    /// A playlist delete that resumes when its file op ends must not be cut short by the quit:
    /// the final save would keep part of its files deleted and the playlist present.
    @Test func aPlaylistDeleteHoldsTheQuitUntilItEnds() async throws {
        let container = try makeContainer()
        let (appState, replies) = makeAppState(container)
        defer { appState.coordinator.shutdown() }
        let (scan, deletion) = try await startHeldDelete(appState, in: container.mainContext)
        appState.busyFileIDs = [UUID()]
        #expect(appState.shouldTerminate() == .terminateLater)

        appState.busyFileIDs = []
        await drainMainActor()
        #expect(replies.values.isEmpty)

        scan.open()
        await deletion.value
        await drainMainActor()
        #expect(replies.values == [true])
    }

    /// A quit during disk work is held, not cancelled: a cancel also stops a logout, restart or
    /// shutdown, which then does not continue when the work ends.
    @Test func aQuitDuringDiskWorkIsHeldNotCancelled() throws {
        let container = try makeContainer()
        let (appState, _) = makeAppState(container)
        let delegate = AppDelegate()
        delegate.appState = appState
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)

        appState.busyFileIDs = [UUID()]
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
    }

    @Test(arguments: [(6, "1 more file"), (7, "2 more files")])
    func theWaitNamesTheBusyFilesAndCountsTheRest(busy: Int, rest: String) async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let (appState, _) = makeAppState(container)
        defer { appState.coordinator.shutdown() }
        let playlist = Playlist(name: "P", folderBookmark: Data(), folderPath: "/tmp/p", mediaType: .image)
        context.insert(playlist)
        let files = "abcdefg".prefix(busy).reversed().enumerated().map { index, name in
            insertFile("\(name).jpg", order: index, to: playlist, in: context)
        }
        try context.save()
        appState.busyFileIDs = Set(files.map(\.id))
        let (scan, deletion) = try await startHeldDelete(appState, in: context)

        #expect(appState.quitWaitItems == ["a.jpg", "b.jpg", "c.jpg", "d.jpg", "e.jpg", rest, "A playlist delete"])
        scan.open()
        await deletion.value
    }

    @Test func theWaitCountsOnlyBusyFilesStillInTheStore() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let (appState, _) = makeAppState(container)
        let playlist = Playlist(name: "P", folderBookmark: Data(), folderPath: "/tmp/p", mediaType: .image)
        context.insert(playlist)
        let files = "abcdef".enumerated().map { index, name in
            insertFile("\(name).jpg", order: index, to: playlist, in: context)
        }
        try context.save()
        appState.busyFileIDs = Set(files.map(\.id)).union([UUID()])

        #expect(appState.quitWaitItems == ["a.jpg", "b.jpg", "c.jpg", "d.jpg", "e.jpg", "1 more file"])
    }

    @Test func theWaitListsTheFilesInFinderOrder() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let (appState, _) = makeAppState(container)
        let playlist = Playlist(name: "P", folderBookmark: Data(), folderPath: "/tmp/p", mediaType: .image)
        context.insert(playlist)
        let files = ["B.jpg", "a.jpg", "10.jpg", "9.jpg"].enumerated().map { index, name in
            insertFile(name, order: index, to: playlist, in: context)
        }
        try context.save()
        appState.busyFileIDs = Set(files.map(\.id))

        #expect(appState.quitWaitItems == ["9.jpg", "10.jpg", "a.jpg", "B.jpg"])
    }
}

@MainActor
private final class Replies {
    var values: [Bool] = []
}
