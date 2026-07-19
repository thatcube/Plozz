#if canImport(UIKit)
import CoreModels
@testable import CoreUI
import SQLite3
import UIKit
import XCTest

final class LocalArtworkDerivedCacheTests: XCTestCase {
    func testInactiveEntriesEvictBeforePreferredAccounts() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let clock = TestClock()
        let cache = LocalArtworkDerivedCache(
            directory: fixture.directory,
            byteCap: 1_000_000,
            warningByteCap: 750_000,
            maximumAge: 30 * 24 * 60 * 60,
            now: { clock.now }
        )
        let image = try Self.image(color: .red)
        await cache.store(
            image,
            key: "active",
            accountID: "active",
            credentialRevision: "revision",
            sourceFingerprint: "active-fingerprint",
            variant: .posterCard
        )
        clock.advance()
        await cache.store(
            image,
            key: "inactive",
            accountID: "inactive",
            credentialRevision: "revision",
            sourceFingerprint: "inactive-fingerprint",
            variant: .posterCard
        )
        let oneEntryCap = max(1, await cache.usageBytes() / 2 + 1)
        await cache.setPreferredAccounts(["active"], revision: 1)
        await cache.trim(to: oneEntryCap)

        let active = await cache.data(
            for: "active",
            accountID: "active",
            credentialRevision: "revision",
            sourceFingerprint: "active-fingerprint"
        )
        let inactive = await cache.data(
            for: "inactive",
            accountID: "inactive",
            credentialRevision: "revision",
            sourceFingerprint: "inactive-fingerprint"
        )
        XCTAssertNotNil(active)
        XCTAssertNil(inactive)
    }

    func testBackgroundReadDoesNotRefreshAgeAndExpiredEntryIsRemovedFirst() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let clock = TestClock()
        let cache = LocalArtworkDerivedCache(
            directory: fixture.directory,
            byteCap: 1_000_000,
            warningByteCap: 750_000,
            maximumAge: 10,
            now: { clock.now }
        )
        await cache.store(
            try Self.image(color: .blue),
            key: "expired",
            accountID: "active",
            credentialRevision: "revision",
            sourceFingerprint: "fingerprint",
            variant: .landscapeCard
        )
        clock.advance(by: 11)
        let backgroundHit = await cache.data(
            for: "expired",
            accountID: "active",
            credentialRevision: "revision",
            sourceFingerprint: "fingerprint",
            markUsed: false
        )
        XCTAssertNotNil(backgroundHit)

        await cache.trim(to: 1_000_000)

        let expired = await cache.data(
            for: "expired",
            accountID: "active",
            credentialRevision: "revision",
            sourceFingerprint: "fingerprint"
        )
        XCTAssertNil(expired)
    }

    func testStalePreferenceRevisionCannotReplaceNewerPolicy() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let cache = LocalArtworkDerivedCache(directory: fixture.directory)
        await cache.setPreferredAccounts(["new"], revision: 2)
        await cache.setPreferredAccounts(["stale"], revision: 1)
        let preferred = await cache.preferredAccountsForTesting()
        XCTAssertEqual(preferred, ["new"])
    }

    func testAccountAndCredentialRevisionPurgesAreScoped() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let cache = LocalArtworkDerivedCache(directory: fixture.directory)
        let image = try Self.image(color: .green)
        for (key, account, revision) in [
            ("a1", "a", "one"),
            ("a2", "a", "two"),
            ("b1", "b", "one"),
        ] {
            await cache.store(
                image,
                key: key,
                accountID: account,
                credentialRevision: revision,
                sourceFingerprint: key,
                variant: .posterCard
            )
        }

        await cache.purge(accountID: "a", credentialRevision: "one")
        let purgedRevision = await cache.data(
            for: "a1", accountID: "a", credentialRevision: "one", sourceFingerprint: "a1"
        )
        let retainedRevision = await cache.data(
            for: "a2", accountID: "a", credentialRevision: "two", sourceFingerprint: "a2"
        )
        let otherAccount = await cache.data(
            for: "b1", accountID: "b", credentialRevision: "one", sourceFingerprint: "b1"
        )
        XCTAssertNil(purgedRevision)
        XCTAssertNotNil(retainedRevision)
        XCTAssertNotNil(otherAccount)

        await cache.purge(accountID: "a")
        let purgedAccount = await cache.data(
            for: "a2", accountID: "a", credentialRevision: "two", sourceFingerprint: "a2"
        )
        let retainedAccount = await cache.data(
            for: "b1", accountID: "b", credentialRevision: "one", sourceFingerprint: "b1"
        )
        XCTAssertNil(purgedAccount)
        XCTAssertNotNil(retainedAccount)
    }

    func testCorruptManifestIsRecreatedAsCacheMiss() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try Data("not sqlite".utf8).write(
            to: fixture.directory.appendingPathComponent("manifest.sqlite")
        )
        let cache = LocalArtworkDerivedCache(directory: fixture.directory)

        let emptyUsage = await cache.usageBytes()
        XCTAssertEqual(emptyUsage, 0)
        await cache.store(
            try Self.image(color: .purple),
            key: "recovered",
            accountID: "account",
            credentialRevision: "revision",
            sourceFingerprint: "fingerprint",
            variant: .posterCard
        )
        let recoveredUsage = await cache.usageBytes()
        XCTAssertGreaterThan(recoveredUsage, 0)
    }

    private static func image(color: UIColor) throws -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32))
        return renderer.image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_000)

    var now: Date {
        lock.withLock { value }
    }

    func advance(by interval: TimeInterval = 1) {
        lock.withLock { value = value.addingTimeInterval(interval) }
    }
}

private struct Fixture {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalArtworkDerivedCacheTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}
#endif
