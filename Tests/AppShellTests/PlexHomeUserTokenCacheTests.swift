import XCTest
import CoreModels
import FeatureAuth
@testable import AppRuntime
@testable import AppShell

/// Unit tests for ``PlexHomeUserTokenCache`` — the persisted cache of resolved
/// server tokens for **unprotected** Plex Home users that lets startup install
/// the right identity synchronously (killing the double-load). Backed by an
/// in-memory secure store so the keychain isn't touched.
final class PlexHomeUserTokenCacheTests: XCTestCase {
    private func makeCache() -> (PlexHomeUserTokenCache, InMemorySecureStore) {
        let store = InMemorySecureStore()
        return (PlexHomeUserTokenCache(store: store), store)
    }

    func testStoreThenReadRoundTrips() {
        let (cache, _) = makeCache()
        XCTAssertNil(cache.token(account: "acctA", homeUser: "userA"))

        cache.store(token: "tok-A", account: "acctA", homeUser: "userA")
        XCTAssertEqual(cache.token(account: "acctA", homeUser: "userA"), "tok-A")
    }

    func testTokensAreScopedPerAccountAndHomeUser() {
        let (cache, _) = makeCache()
        cache.store(token: "tok-A1", account: "acctA", homeUser: "user1")
        cache.store(token: "tok-A2", account: "acctA", homeUser: "user2")
        cache.store(token: "tok-B1", account: "acctB", homeUser: "user1")

        XCTAssertEqual(cache.token(account: "acctA", homeUser: "user1"), "tok-A1")
        XCTAssertEqual(cache.token(account: "acctA", homeUser: "user2"), "tok-A2")
        XCTAssertEqual(cache.token(account: "acctB", homeUser: "user1"), "tok-B1")
        XCTAssertNil(cache.token(account: "acctB", homeUser: "user2"))
    }

    func testStoreUpsertsExistingEntry() {
        let (cache, _) = makeCache()
        cache.store(token: "old", account: "acctA", homeUser: "user1")
        cache.store(token: "new", account: "acctA", homeUser: "user1")
        XCTAssertEqual(cache.token(account: "acctA", homeUser: "user1"), "new")
    }

    func testRemoveSingleEntryLeavesOthers() {
        let (cache, _) = makeCache()
        cache.store(token: "tok-1", account: "acctA", homeUser: "user1")
        cache.store(token: "tok-2", account: "acctA", homeUser: "user2")

        cache.remove(account: "acctA", homeUser: "user1")

        XCTAssertNil(cache.token(account: "acctA", homeUser: "user1"))
        XCTAssertEqual(cache.token(account: "acctA", homeUser: "user2"), "tok-2")
    }

    func testRemoveAllForAccountPurgesEveryHomeUser() {
        let (cache, _) = makeCache()
        cache.store(token: "tok-1", account: "acctA", homeUser: "user1")
        cache.store(token: "tok-2", account: "acctA", homeUser: "user2")
        cache.store(token: "tok-B", account: "acctB", homeUser: "user1")

        cache.removeAll(account: "acctA")

        XCTAssertNil(cache.token(account: "acctA", homeUser: "user1"))
        XCTAssertNil(cache.token(account: "acctA", homeUser: "user2"))
        XCTAssertEqual(cache.token(account: "acctB", homeUser: "user1"), "tok-B",
                       "Other accounts are untouched")
    }

    func testRemoveAllPurgesEverything() {
        let (cache, _) = makeCache()
        cache.store(token: "tok-1", account: "acctA", homeUser: "user1")
        cache.store(token: "tok-B", account: "acctB", homeUser: "user1")

        cache.removeAll()

        XCTAssertNil(cache.token(account: "acctA", homeUser: "user1"))
        XCTAssertNil(cache.token(account: "acctB", homeUser: "user1"))
    }

    func testCachePersistsAcrossInstancesSharingStore() {
        let store = InMemorySecureStore()
        PlexHomeUserTokenCache(store: store).store(token: "tok-A", account: "acctA", homeUser: "user1")

        // A fresh cache over the same backing store (a relaunch) sees the token.
        let reopened = PlexHomeUserTokenCache(store: store)
        XCTAssertEqual(reopened.token(account: "acctA", homeUser: "user1"), "tok-A")
    }
}
