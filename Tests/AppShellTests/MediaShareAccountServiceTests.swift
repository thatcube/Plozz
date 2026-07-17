import XCTest
import CoreModels
import FeatureAuth
import MediaTransportCore
@testable import AppShell

/// Batch 11 unit coverage for `MediaShareAccountService` (media-share account
/// lifecycle routing) plus source-inspection gates proving AppState no longer
/// owns adapter/session-key/credential construction policy or a split init.
final class MediaShareAccountServiceTests: XCTestCase {

    /// Minimal runtime spy for the service-level tests.
    private final class RuntimeSpy: MediaShareRuntime, @unchecked Sendable {
        private final class NullResolver: MediaTransportNetworkFileResolving, @unchecked Sendable {
            func resolve(_ locator: NetworkFileLocator) async throws -> MediaTransportResolvedSource {
                throw MediaTransportError.unsupportedCapability("null")
            }
        }
        let networkFileResolver: any MediaTransportNetworkFileResolving = NullResolver()

        private let lock = NSLock()
        private var _retire: [(String, CredentialRevision)] = []
        private var _invalidate: [String] = []

        func registerProvider(into registry: ProviderRegistry, durableLocalStateStore: DurableLocalStateStore?) {}
        func configure(reporter: ShareScanReporter) async {}
        func invalidate(accountKey: String) async { lock.lock(); _invalidate.append(accountKey); lock.unlock() }
        func retire(accountID: String, credentialRevision: CredentialRevision) async {
            lock.lock(); _retire.append((accountID, credentialRevision)); lock.unlock()
        }
        func setPreferredAccountKeys(_ accountKeys: Set<String>, revision: UInt64) async {}

        var retire: [(String, CredentialRevision)] { lock.lock(); defer { lock.unlock() }; return _retire }
        var invalidate: [String] { lock.lock(); defer { lock.unlock() }; return _invalidate }
    }

    private func account(id: String, provider: ProviderKind) -> Account {
        let server = MediaServer(
            id: id,
            name: id,
            baseURL: URL(string: "smb://host/\(id)")!,
            provider: provider
        )
        return Account(id: id, server: server, userID: "u", userName: "u", deviceID: "d")
    }

    private func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval = 2.0) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func testMediaShareKeyDerivation() {
        let spy = RuntimeSpy()
        let service = MediaShareAccountService(runtime: spy)
        let share = account(id: "s1", provider: .mediaShare)
        let plex = account(id: "p1", provider: .plex)

        XCTAssertEqual(service.mediaShareAccountKey(for: share), "s1")
        XCTAssertNil(service.mediaShareAccountKey(for: plex))
        XCTAssertNil(service.mediaShareAccountKey(for: nil))
        XCTAssertEqual(service.mediaShareAccountKeys(in: [share, plex]), ["s1"])
    }

    func testRetireCredentialIsNoOpForNonMediaShare() async {
        let spy = RuntimeSpy()
        let service = MediaShareAccountService(runtime: spy)
        service.retireCredential(for: account(id: "p1", provider: .plex))
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(spy.retire.isEmpty, "non-media-share accounts must not retire transport sessions")
    }

    func testRetireCredentialRoutesExactRevision() async {
        let spy = RuntimeSpy()
        let service = MediaShareAccountService(runtime: spy)
        let share = account(id: "s1", provider: .mediaShare)
        service.retireCredential(for: share)
        await waitUntil { spy.retire.count == 1 }
        XCTAssertEqual(spy.retire.first?.0, "s1")
        XCTAssertEqual(spy.retire.first?.1, share.credentialRevision)
    }

    func testInvalidateRoutesThroughRuntime() async {
        let spy = RuntimeSpy()
        let service = MediaShareAccountService(runtime: spy)
        service.invalidate(shareAccountKey: "s1")
        await waitUntil { spy.invalidate == ["s1"] }
        XCTAssertEqual(spy.invalidate, ["s1"])
    }

    // MARK: - Source-inspection gates

    private func appStateSource() throws -> String {
        // Tests/AppShellTests/<this file> -> repo root -> Sources/AppShell/AppState.swift
        let thisFile = URL(fileURLWithPath: #filePath)
        let root = thisFile.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appState = root
            .appendingPathComponent("Sources/AppShell/AppState.swift")
        return try String(contentsOf: appState, encoding: .utf8)
    }

    func testAppStateInitHasNoSplitRuntimeParameters() throws {
        let source = try appStateSource()
        XCTAssertTrue(source.contains("mediaShareRuntime: (any MediaShareRuntime)?"),
                      "AppState must accept exactly one atomic runtime")
        XCTAssertFalse(source.contains("networkFileResolver: (any MediaTransportNetworkFileResolving)?"),
                       "AppState must not accept an independently-injectable network-file resolver")
        XCTAssertFalse(source.contains("shareCatalogCoordinator: ShareCatalogCoordinator?"),
                       "AppState must not accept an independently-injectable coordinator")
    }

    func testAppStateContainsNoTransportConstructionPolicy() throws {
        let source = try appStateSource()
        for forbidden in [
            "makeSMBAdapter",
            "makeWebDAVAdapter",
            "makeSFTPAdapter",
            "makeFTPAdapter",
            "makeMediaShareAdapters",
            "makeMediaShareRegistry",
            "mediaShareSessionKey",
            "webDAVConfiguration",
            "sftpConfiguration",
            "ftpConfiguration",
        ] {
            XCTAssertFalse(
                source.contains(forbidden),
                "AppState must not contain media-share transport construction policy: \(forbidden)"
            )
        }
    }
}
