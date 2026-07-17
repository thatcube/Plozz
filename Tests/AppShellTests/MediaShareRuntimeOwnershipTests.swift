import XCTest
import CoreModels
import FeatureAuth
import MediaTransportCore
@testable import AppShell

/// Batch 11 (E3/E4) coverage: the media-share runtime is one atomic ownership
/// generation, and AppState routes every media-share concern
/// (provider registration, reporter wiring, playback resolver, credential
/// retirement, account invalidation, preferred priority) through that single
/// runtime rather than assembling independent coordinator/resolver/registry
/// pieces.
@MainActor
final class MediaShareRuntimeOwnershipTests: XCTestCase {

    // MARK: - Doubles

    /// A network-file resolver that only needs a stable identity for forwarding
    /// assertions; it never actually resolves in these tests.
    private final class FakeNetworkFileResolver: MediaTransportNetworkFileResolving, @unchecked Sendable {
        func resolve(_ locator: NetworkFileLocator) async throws -> MediaTransportResolvedSource {
            throw MediaTransportError.unsupportedCapability("fake resolver")
        }
    }

    /// A complete fake runtime. Records every call the app state makes so a test
    /// can prove the *same* runtime identity is used across registration,
    /// reporter wiring, retirement, invalidation, and priority updates.
    private final class SpyMediaShareRuntime: MediaShareRuntime, @unchecked Sendable {
        let fakeResolver = FakeNetworkFileResolver()
        var networkFileResolver: any MediaTransportNetworkFileResolving { fakeResolver }

        private let lock = NSLock()
        private var _registeredProviderCount = 0
        private var _reporterConfiguredCount = 0
        private var _retireCalls: [(accountID: String, revision: CredentialRevision)] = []
        private var _invalidateCalls: [String] = []
        private var _preferredCalls: [(keys: Set<String>, revision: UInt64)] = []

        func registerProvider(
            into registry: ProviderRegistry,
            durableLocalStateStore: DurableLocalStateStore?
        ) {
            lock.lock(); _registeredProviderCount += 1; lock.unlock()
        }

        func configure(reporter: ShareScanReporter) async {
            lock.lock(); _reporterConfiguredCount += 1; lock.unlock()
        }

        func invalidate(accountKey: String) async {
            lock.lock(); _invalidateCalls.append(accountKey); lock.unlock()
        }

        func retire(accountID: String, credentialRevision: CredentialRevision) async {
            lock.lock(); _retireCalls.append((accountID, credentialRevision)); lock.unlock()
        }

        func setPreferredAccountKeys(_ accountKeys: Set<String>, revision: UInt64) async {
            lock.lock(); _preferredCalls.append((accountKeys, revision)); lock.unlock()
        }

        var registeredProviderCount: Int { lock.lock(); defer { lock.unlock() }; return _registeredProviderCount }
        var reporterConfiguredCount: Int { lock.lock(); defer { lock.unlock() }; return _reporterConfiguredCount }
        var retireCalls: [(accountID: String, revision: CredentialRevision)] {
            lock.lock(); defer { lock.unlock() }; return _retireCalls
        }
        var invalidateCalls: [String] { lock.lock(); defer { lock.unlock() }; return _invalidateCalls }
        var preferredCalls: [(keys: Set<String>, revision: UInt64)] {
            lock.lock(); defer { lock.unlock() }; return _preferredCalls
        }
    }

    /// Wraps a real `AccountStore` but can be told to fail (and NOT mutate)
    /// removal/clear, so the "failed persistence removal performs no runtime
    /// invalidation" guard can be exercised.
    private final class FailingRemovalAccountStore: AccountPersisting, @unchecked Sendable {
        private let wrapped: AccountStore
        let failRemove: Bool
        let failClear: Bool

        init(wrapped: AccountStore, failRemove: Bool = false, failClear: Bool = false) {
            self.wrapped = wrapped
            self.failRemove = failRemove
            self.failClear = failClear
        }

        func deviceID() -> String { wrapped.deviceID() }
        func loadAccounts() -> [Account] { wrapped.loadAccounts() }
        func activeAccountIDs() -> [String] { wrapped.activeAccountIDs() }
        func setActiveAccountIDs(_ ids: [String]) { wrapped.setActiveAccountIDs(ids) }
        func token(for accountID: String) -> String? { wrapped.token(for: accountID) }
        func mediaShareCredential(for accountID: String) throws -> MediaShareCredentialEnvelope {
            try wrapped.mediaShareCredential(for: accountID)
        }
        func mediaShareCredential(
            for accountID: String,
            revision: CredentialRevision
        ) throws -> MediaShareCredentialEnvelope {
            try wrapped.mediaShareCredential(for: accountID, revision: revision)
        }
        func add(_ account: Account, token: String) throws { try wrapped.add(account, token: token) }
        func addMediaShare(
            _ account: Account,
            credential: MediaShareCredentialEnvelope,
            generatedPrivateKey: String?
        ) throws {
            try wrapped.addMediaShare(account, credential: credential, generatedPrivateKey: generatedPrivateKey)
        }
        func remove(id: String) throws {
            if failRemove { throw AccountStoreError.invalidMediaShareAccount }
            try wrapped.remove(id: id)
        }
        func clearAll() throws {
            if failClear { throw AccountStoreError.invalidMediaShareAccount }
            try wrapped.clearAll()
        }
        func recoverCredentialMutations() throws { try wrapped.recoverCredentialMutations() }
    }

    // MARK: - Harness

    private struct Harness {
        let state: AppState
        let store: AccountPersisting
        let runtime: SpyMediaShareRuntime
    }

    private func makeStore() throws -> AccountStore {
        let secure = InMemorySecureStore()
        let vault = MediaCredentialVault(secureStore: secure)
        let journal = try CredentialMutationJournal(
            store: DurableLocalStateStore(secureStore: InMemorySecureStore())
        )
        return AccountStore(secureStore: secure, mediaCredentialVault: vault, credentialJournal: journal)
    }

    private func makeHarness(store: AccountPersisting? = nil) throws -> Harness {
        let resolvedStore = try store ?? makeStore()
        let runtime = SpyMediaShareRuntime()
        let defaults = UserDefaults(suiteName: "MediaShareRuntimeOwnershipTests.\(UUID().uuidString)")!
        let profiles = ProfilesModel(store: ProfileStore(defaults: defaults))
        let state = AppState(
            accountStore: resolvedStore,
            mediaShareRuntime: runtime,
            profilesModel: profiles
        )
        state.bootstrap()
        return Harness(state: state, store: resolvedStore, runtime: runtime)
    }

    private func addShare(
        _ state: AppState,
        host: String = "192.168.1.10",
        share: String = "Media",
        username: String = "brandon",
        password: String = "pw"
    ) -> Account {
        state.didConfigureShare(
            host: host, port: nil, share: share,
            username: username, password: password, displayName: share
        )
        return state.accounts.first { $0.server.provider == .mediaShare && $0.userName == username }!
    }

    /// Polls the main actor until `condition` holds or a short deadline passes,
    /// letting the fire-and-forget retire/invalidate Tasks land.
    private func waitUntil(
        _ condition: @escaping () -> Bool,
        timeout: TimeInterval = 2.0,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition(), message, file: file, line: line)
    }

    // MARK: - Registration / reporter / resolver forwarding

    func testInjectedRuntimeReceivesProviderRegistrationAndReporter() async throws {
        let harness = try makeHarness()
        // registerProvider runs synchronously during makeDefaultRegistry.
        XCTAssertEqual(harness.runtime.registeredProviderCount, 1)
        // configure(reporter:) is dispatched from init.
        await waitUntil({ harness.runtime.reporterConfiguredCount == 1 },
                        "reporter should be configured through the injected runtime")
    }

    func testNetworkFileResolverForwardsToRuntime() throws {
        let harness = try makeHarness()
        XCTAssertTrue(
            harness.state.networkFileResolver as AnyObject === harness.runtime.fakeResolver,
            "AppState.networkFileResolver must forward to the runtime's resolver instance"
        )
    }

    // MARK: - Removal routes retire + invalidate at the exact generation

    func testRemoveAccountRoutesRetireAndInvalidateWithExactRevision() async throws {
        let harness = try makeHarness()
        let account = addShare(harness.state)
        let revision = account.credentialRevision

        harness.state.removeAccount(id: account.id)

        await waitUntil({ harness.runtime.retireCalls.count == 1 && harness.runtime.invalidateCalls.count == 1 },
                        "removal must route exactly one retire and one invalidate through the runtime")
        let retire = harness.runtime.retireCalls[0]
        XCTAssertEqual(retire.accountID, account.id)
        XCTAssertEqual(retire.revision, revision,
                       "retirement must target the exact credential generation that vended the account")
        XCTAssertEqual(harness.runtime.invalidateCalls[0], account.id)
    }

    func testFailedStoreRemovalPerformsNoRuntimeInvalidation() async throws {
        let realStore = try makeStore()
        // Seed the share on the real store first, then wrap it so removal fails.
        let seedRuntime = SpyMediaShareRuntime()
        let defaults = UserDefaults(suiteName: "MediaShareRuntimeOwnershipTests.seed.\(UUID().uuidString)")!
        let seedState = AppState(
            accountStore: realStore,
            mediaShareRuntime: seedRuntime,
            profilesModel: ProfilesModel(store: ProfileStore(defaults: defaults))
        )
        let account = addShare(seedState)

        let failingStore = FailingRemovalAccountStore(wrapped: realStore, failRemove: true)
        let harness = try makeHarness(store: failingStore)
        XCTAssertTrue(harness.state.accounts.contains { $0.id == account.id })

        harness.state.removeAccount(id: account.id)

        // Give any (incorrectly) dispatched work a chance to land, then assert none did.
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(harness.state.accounts.contains { $0.id == account.id },
                      "a failed persistence removal must leave the account signed in")
        XCTAssertEqual(harness.runtime.retireCalls.count, 0,
                       "no retirement may run when persistence removal failed")
        XCTAssertEqual(harness.runtime.invalidateCalls.count, 0,
                       "no invalidation may run when persistence removal failed")
    }

    // MARK: - signOutAll only touches confirmed removals

    func testSignOutAllInvalidatesOnlyConfirmedRemovedShares() async throws {
        let harness = try makeHarness()
        let a = addShare(harness.state, share: "MediaA", username: "brandon")
        let b = addShare(harness.state, share: "MediaB", username: "sister")

        harness.state.signOutAll()

        await waitUntil({ harness.runtime.invalidateCalls.count == 2 },
                        "both confirmed-removed shares must be invalidated")
        XCTAssertEqual(Set(harness.runtime.invalidateCalls), Set([a.id, b.id]))
        XCTAssertEqual(Set(harness.runtime.retireCalls.map(\.accountID)), Set([a.id, b.id]))
    }

    func testSignOutAllWithFailedClearInvalidatesNothing() async throws {
        let realStore = try makeStore()
        let seedRuntime = SpyMediaShareRuntime()
        let defaults = UserDefaults(suiteName: "MediaShareRuntimeOwnershipTests.seedClear.\(UUID().uuidString)")!
        let seedState = AppState(
            accountStore: realStore,
            mediaShareRuntime: seedRuntime,
            profilesModel: ProfilesModel(store: ProfileStore(defaults: defaults))
        )
        _ = addShare(seedState)

        let failingStore = FailingRemovalAccountStore(wrapped: realStore, failClear: true)
        let harness = try makeHarness(store: failingStore)
        XCTAssertFalse(harness.state.accounts.isEmpty)

        harness.state.signOutAll()

        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(harness.runtime.retireCalls.count, 0)
        XCTAssertEqual(harness.runtime.invalidateCalls.count, 0,
                       "retained accounts after a failed clear must not be invalidated")
    }

    // MARK: - Preferred priority routes through the runtime

    func testReloadRoutesPreferredAccountKeysThroughRuntime() async throws {
        let harness = try makeHarness()
        let account = addShare(harness.state)

        await waitUntil({ harness.runtime.preferredCalls.contains { $0.keys.contains(account.id) } },
                        "the active profile's preferred share keys must be pushed through the runtime")
    }

    // MARK: - Repeated remove/re-add keeps one runtime generation

    func testRepeatedRemoveReAddDoesNotForkRuntimeGeneration() async throws {
        let harness = try makeHarness()
        for _ in 0..<3 {
            let account = addShare(harness.state)
            harness.state.removeAccount(id: account.id)
        }
        await waitUntil({ harness.runtime.invalidateCalls.count == 3 },
                        "each removal invalidates against the one retained runtime")
        // The provider factory was registered exactly once (at init); re-adds
        // never build a new runtime/registry.
        XCTAssertEqual(harness.runtime.registeredProviderCount, 1,
                       "re-adding a share must not construct a new runtime generation")
    }
}
