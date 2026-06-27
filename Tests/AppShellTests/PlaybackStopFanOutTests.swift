import XCTest
@testable import AppShell
import CoreModels

final class PlaybackStopFanOutTests: XCTestCase {
    func testPlaybackStopHonorsCrossServerSyncOffAtStopTime() {
        let item = MediaItem(
            id: "origin-item",
            title: "Dune",
            kind: .movie,
            runtime: 100,
            providerIDs: ["Tmdb": "438631"],
            sourceAccountID: "origin"
        )
        let lookup = MutableIdentityLookup()
        let recorder = PlaybackStopRecorder()
        // Live reader returns OFF: the stop must scope to the origin server only,
        // even though the warm identity union knows peer servers.
        let bridge = WatchOutboxBridge(
            beginLiveSession: { _, _ in },
            finishPlayback: { accountID, itemID, _, mutation in
                recorder.record(accountID: accountID, itemID: itemID, mutation: mutation)
            },
            checkpoint: { _ in },
            crossServerSync: { false }
        )

        let handler = makePlaybackStoppedHandler(
            convergingItem: item,
            primaryAccountID: "origin",
            liveAccountID: "origin",
            liveItemID: "origin-item",
            watchBridge: bridge,
            identitySources: lookup.sources(for:)
        )

        lookup.sources = [
            MediaSourceRef(accountID: "origin", itemID: "origin-item", providerKind: .jellyfin),
            MediaSourceRef(accountID: "plex", itemID: "plex-item", providerKind: .plex),
            MediaSourceRef(accountID: "jellyfin-two", itemID: "jf-two-item", providerKind: .jellyfin)
        ]

        handler(95, 95)

        let call = recorder.onlyCall
        XCTAssertEqual(
            call?.mutation?.targets,
            [WatchMutationTarget(accountID: "origin", itemID: "origin-item", providerKind: .jellyfin)],
            "With sync OFF the stop must converge on the origin server only"
        )
        XCTAssertEqual(call?.mutation?.expansionPending, false, "Sync OFF must suppress drain-time re-expansion")
        XCTAssertEqual(call?.mutation?.identities, [], "Sync OFF must carry no identity seeds")
    }

    func testPlaybackStopFanOutUsesLiveIdentitySourcesAtStopTime() {
        let item = MediaItem(
            id: "origin-item",
            title: "Dune",
            kind: .movie,
            runtime: 100,
            providerIDs: ["Tmdb": "438631"],
            sourceAccountID: "origin"
        )
        let lookup = MutableIdentityLookup()
        let recorder = PlaybackStopRecorder()
        let bridge = WatchOutboxBridge(
            beginLiveSession: { _, _ in },
            finishPlayback: { accountID, itemID, _, mutation in
                recorder.record(accountID: accountID, itemID: itemID, mutation: mutation)
            },
            checkpoint: { _ in },
            crossServerSync: { true }
        )

        let handler = makePlaybackStoppedHandler(
            convergingItem: item,
            primaryAccountID: "origin",
            liveAccountID: "origin",
            liveItemID: "origin-item",
            watchBridge: bridge,
            identitySources: lookup.sources(for:)
        )

        lookup.sources = [
            MediaSourceRef(accountID: "origin", itemID: "origin-item", providerKind: .jellyfin),
            MediaSourceRef(accountID: "plex", itemID: "plex-item", providerKind: .plex),
            MediaSourceRef(accountID: "jellyfin-two", itemID: "jf-two-item", providerKind: .jellyfin)
        ]

        handler(95, 95)

        let call = recorder.onlyCall
        XCTAssertEqual(call?.accountID, "origin")
        XCTAssertEqual(call?.itemID, "origin-item")
        XCTAssertEqual(
            call?.mutation?.targets,
            [
                WatchMutationTarget(accountID: "origin", itemID: "origin-item", providerKind: .jellyfin),
                WatchMutationTarget(accountID: "plex", itemID: "plex-item", providerKind: .plex),
                WatchMutationTarget(accountID: "jellyfin-two", itemID: "jf-two-item", providerKind: .jellyfin)
            ],
            "Targets must come from the live warmed identity snapshot at stop time, not the empty creation-time snapshot"
        )
    }

    func testPlaybackCheckpointFansOutToUnionWithoutEndingSession() {
        let item = MediaItem(
            id: "origin-item",
            title: "Dune",
            kind: .movie,
            runtime: 100,
            providerIDs: ["Tmdb": "438631"],
            sourceAccountID: "origin"
        )
        let lookup = MutableIdentityLookup()
        let checkpoints = CheckpointRecorder()
        var finishCalls = 0
        let bridge = WatchOutboxBridge(
            beginLiveSession: { _, _ in },
            finishPlayback: { _, _, _, _ in finishCalls += 1 },
            checkpoint: { mutation in checkpoints.record(mutation) },
            crossServerSync: { true }
        )

        let handler = makePlaybackCheckpointHandler(
            convergingItem: item,
            primaryAccountID: "origin",
            watchBridge: bridge,
            identitySources: lookup.sources(for:)
        )

        lookup.sources = [
            MediaSourceRef(accountID: "origin", itemID: "origin-item", providerKind: .jellyfin),
            MediaSourceRef(accountID: "plex", itemID: "plex-item", providerKind: .plex)
        ]

        // A partial mid-play position (~50%): converge resume to every server, but
        // never end the live session (that only happens at stop).
        handler(50, 50)

        let mutation = checkpoints.onlyMutation
        XCTAssertEqual(
            mutation??.targets,
            [
                WatchMutationTarget(accountID: "origin", itemID: "origin-item", providerKind: .jellyfin),
                WatchMutationTarget(accountID: "plex", itemID: "plex-item", providerKind: .plex)
            ],
            "A checkpoint must fan the resume position out to the full warmed union"
        )
        XCTAssertEqual(mutation??.played, nil, "A partial checkpoint must not mark the item played")
        XCTAssertEqual(finishCalls, 0, "A checkpoint must not end the live session")
    }
}

private final class CheckpointRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var mutations: [WatchMutation?] = []

    var onlyMutation: WatchMutation?? {
        lock.lock()
        defer { lock.unlock() }
        XCTAssertEqual(mutations.count, 1)
        return mutations.first
    }

    func record(_ mutation: WatchMutation?) {
        lock.lock()
        mutations.append(mutation)
        lock.unlock()
    }
}

private final class MutableIdentityLookup: @unchecked Sendable {
    private let lock = NSLock()
    private var storedSources: [MediaSourceRef] = []

    var sources: [MediaSourceRef] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedSources
        }
        set {
            lock.lock()
            storedSources = newValue
            lock.unlock()
        }
    }

    func sources(for item: MediaItem) -> [MediaSourceRef] {
        sources
    }
}

private final class PlaybackStopRecorder: @unchecked Sendable {
    struct Call {
        let accountID: String?
        let itemID: String
        let mutation: WatchMutation?
    }

    private let lock = NSLock()
    private var calls: [Call] = []

    var onlyCall: Call? {
        lock.lock()
        defer { lock.unlock() }
        XCTAssertEqual(calls.count, 1)
        return calls.first
    }

    func record(accountID: String?, itemID: String, mutation: WatchMutation?) {
        lock.lock()
        calls.append(Call(accountID: accountID, itemID: itemID, mutation: mutation))
        lock.unlock()
    }
}
