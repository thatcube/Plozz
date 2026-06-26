import XCTest
@testable import AppShell
import CoreModels

final class PlaybackStopFanOutTests: XCTestCase {
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
            finishPlayback: { accountID, itemID, mutation in
                recorder.record(accountID: accountID, itemID: itemID, mutation: mutation)
            }
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
