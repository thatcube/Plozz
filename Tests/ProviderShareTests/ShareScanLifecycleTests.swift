import CoreModels
import Foundation
import MediaTransportCore
import XCTest
@testable import ProviderShare

/// Batch 3 (findings A5 + A7): explicit scan outcomes drive *conditional* background
/// completion stamping (a cancelled/superseded/invalidated pass must never suppress the
/// next needed scan), every non-completing scan is attributed to an exact secret-safe
/// owner, and a per-account arbiter is retired (drained + removed) once its account is
/// invalidated so arbiters never accumulate.
///
/// These are behavior tests against the real `ShareCatalogCoordinator`/`ShareScanner`
/// (only the transport session + diagnostics sink are injected), so they exercise the
/// production completion-gating, owner-attribution, and arbiter-retirement paths.
final class ShareScanLifecycleTests: XCTestCase {

    // MARK: - Test doubles

    /// Captures the secret-safe non-completion records the coordinator emits so a test
    /// can assert the exact owner/generation of each scan that did not stamp completion.
    private final class ScanDiagnosticsSpy: ShareScanDiagnostics, @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [ShareScanCancellationRecord] = []
        var records: [ShareScanCancellationRecord] { lock.withLock { storage } }
        func recordCancellation(_ record: ShareScanCancellationRecord) {
            lock.withLock { storage.append(record) }
        }
    }

    /// Controls a scan's directory walk deterministically:
    /// - optionally *blocks* the root listing until the scan task is cancelled OR the
    ///   session is force-closed (mirroring a real SMB read aborting on teardown),
    /// - counts how many real walks reached the root (so a coalesced re-access proves it
    ///   spawned no new scan),
    /// - can inject a subdirectory whose listing fails, forcing a `.completedPartial`.
    private final class LifecycleListController: @unchecked Sendable {
        private let lock = NSLock()
        private var openedFlag = false
        private var startedCount = 0
        private var rootListCountValue = 0
        private var shutdownCountValue = 0
        let blocksRoot: Bool
        let tree: [String: [String]]
        let failingDirs: Set<String>

        init(
            blocksRoot: Bool,
            tree: [String: [String]] = [:],
            failingDirs: Set<String> = []
        ) {
            self.blocksRoot = blocksRoot
            self.tree = tree
            self.failingDirs = failingDirs
        }

        var rootLists: Int { lock.withLock { rootListCountValue } }
        var shutdownCount: Int { lock.withLock { shutdownCountValue } }
        private var isOpened: Bool { lock.withLock { openedFlag } }
        private var hasStarted: Bool { lock.withLock { startedCount > 0 } }

        func noteShutdown() {
            lock.withLock {
                shutdownCountValue += 1
                openedFlag = true
            }
        }

        func noteRootList() {
            lock.withLock {
                rootListCountValue += 1
                startedCount += 1
            }
        }

        func children(of relativePath: String) -> [String] {
            tree[relativePath] ?? []
        }

        func shouldFail(_ relativePath: String) -> Bool {
            failingDirs.contains(relativePath)
        }

        func waitUntilListing(timeout: TimeInterval = 3) async {
            let deadline = Date().addingTimeInterval(timeout)
            while !hasStarted && Date() < deadline {
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        }

        /// Blocks the root listing until force-close (open) or task cancellation.
        func blockRoot() async {
            guard blocksRoot else { return }
            while !isOpened && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        }
    }

    private final class LifecycleFileSystem: MediaTransportFileSystem, @unchecked Sendable {
        private let controller: LifecycleListController
        init(controller: LifecycleListController) { self.controller = controller }

        func validate() async throws {}

        func probe() async throws -> MediaTransportProbe {
            MediaTransportProbe(
                capabilities: try MediaTransportCapabilities(
                    supportsList: true,
                    supportsStat: true,
                    supportsBoundedWholeFileRead: false,
                    byteRangeBehavior: .unsupported,
                    maximumBoundedWholeFileReadBytes: nil,
                    consistency: .changeDetecting
                )
            )
        }

        func list(relativePath: String) async throws -> [RemoteFileEntry] {
            if relativePath.isEmpty {
                controller.noteRootList()
                await controller.blockRoot()
            }
            if controller.shouldFail(relativePath) {
                throw MediaTransportError.unsupportedCapability("injected listing failure")
            }
            return try controller.children(of: relativePath).map {
                try RemoteFileEntry(relativePath: $0, kind: .directory, modifiedAt: Date())
            }
        }

        func stat(relativePath: String) async throws -> RemoteFileEntry {
            throw MediaTransportError.unsupportedCapability("stat")
        }

        func readSmallFile(relativePath: String, maximumBytes: Int) async throws -> Data {
            throw MediaTransportError.unsupportedCapability("bounded read")
        }

        func openSource(for locator: NetworkFileLocator) async throws -> MediaTransportSourceLease {
            throw MediaTransportError.unsupportedCapability("source")
        }
    }

    private final class LifecycleSession: MediaTransportSession, @unchecked Sendable {
        let key: MediaTransportSessionKey
        let fileSystem: any MediaTransportFileSystem
        private let controller: LifecycleListController

        init(key: MediaTransportSessionKey, controller: LifecycleListController) {
            self.key = key
            self.controller = controller
            self.fileSystem = LifecycleFileSystem(controller: controller)
        }

        func shutdown() async { controller.noteShutdown() }
    }

    // MARK: - Harness

    private func makeSessionFactory(
        accountID: String,
        revision: CredentialRevision,
        controller: LifecycleListController
    ) -> ShareTransportSessionFactory {
        { role in
            LifecycleSession(
                key: try! MediaTransportSessionKey(
                    accountID: accountID,
                    credentialRevision: revision,
                    endpoint: try! MediaTransportEndpointIdentity(
                        transportIdentifier: "smb",
                        host: "nas.invalid",
                        rootPath: "/Media"
                    ),
                    trustRevision: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
                    role: role
                ),
                controller: controller
            )
        }
    }

    private func makeCoordinator(
        diagnostics: ScanDiagnosticsSpy
    ) -> ShareCatalogCoordinator {
        ShareCatalogCoordinator(
            arbiterFactory: { MediaIOArbiter(accountID: $0) },
            diagnostics: diagnostics,
            pipelineFactory: TestPipelineFactory { MetadataResolverSpy() }
        )
    }

    @discardableResult
    private func poll(
        timeout: TimeInterval = 3,
        _ condition: @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await condition()
    }

    // MARK: - A5: completion gating and owner attribution

    /// A clean pass stamps completion, and a subsequent access within the coalesce
    /// window spawns no additional walk (fresh no-op). No non-completion record.
    func testCleanScanStampsCompletionAndCoalesces() async throws {
        let accountID = "clean-\(UUID().uuidString)"
        let revision = CredentialRevision()
        let diagnostics = ScanDiagnosticsSpy()
        let controller = LifecycleListController(blocksRoot: false)
        let coordinator = makeCoordinator(diagnostics: diagnostics)
        let factory = makeSessionFactory(
            accountID: accountID, revision: revision, controller: controller
        )

        _ = await coordinator.store(
            accountKey: accountID, displayName: "NAS",
            credentialRevision: revision, sessionFactory: factory
        )
        let stamped = await poll { await coordinator.backgroundScanCompletedAt(accountID) != nil }
        XCTAssertTrue(stamped, "a clean completed pass must stamp background completion")
        XCTAssertTrue(diagnostics.records.isEmpty, "a clean pass records no non-completion")

        // A burst of further accesses within the window must coalesce (no new walk).
        for _ in 0..<5 {
            _ = await coordinator.store(
                accountKey: accountID, displayName: "NAS",
                credentialRevision: revision, sessionFactory: factory
            )
        }
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(controller.rootLists, 1, "repeated access must coalesce to one walk")

        await coordinator.invalidate(accountKey: accountID)
    }

    /// A scan cancelled by playback admission never stamps completion, is attributed to
    /// the playback owner, and the *next* access (after the lease releases) rescans.
    func testCancelledScanByPlaybackLeavesCompletionNilAndRescans() async throws {
        let accountID = "cancel-\(UUID().uuidString)"
        let revision = CredentialRevision()
        let diagnostics = ScanDiagnosticsSpy()
        let controller = LifecycleListController(blocksRoot: true)
        let coordinator = makeCoordinator(diagnostics: diagnostics)
        let factory = makeSessionFactory(
            accountID: accountID, revision: revision, controller: controller
        )

        _ = await coordinator.store(
            accountKey: accountID, displayName: "NAS",
            credentialRevision: revision, sessionFactory: factory
        )
        await controller.waitUntilListing()

        // Playback admission drains (cancels) the in-flight scan.
        let playback = try await coordinator.acquirePlayback(accountKey: accountID)

        let recorded = await poll {
            diagnostics.records.contains { $0.owner == .playbackAdmission }
        }
        XCTAssertTrue(recorded, "a playback-cancelled scan must record the playback owner")
        let completion = await coordinator.backgroundScanCompletedAt(accountID)
        XCTAssertNil(completion, "a cancelled scan must not stamp completion")
        XCTAssertEqual(
            diagnostics.records.filter { $0.owner == .playbackAdmission }.count, 1,
            "exactly one owner-attributed record"
        )

        // Releasing the lease and re-accessing must spawn a fresh scan (not suppressed).
        await playback.releaseAndWait()
        _ = await coordinator.store(
            accountKey: accountID, displayName: "NAS",
            credentialRevision: revision, sessionFactory: factory
        )
        let rescanned = await poll { controller.rootLists >= 2 }
        XCTAssertTrue(rescanned, "the next access after a cancelled scan must rescan")

        await coordinator.invalidate(accountKey: accountID)
    }

    /// A rescan ("Scan now") supersedes an in-flight background pass. The superseded
    /// pass is attributed to the rescan owner and never stamps completion.
    func testRescanSupersessionRecordsRescanOwner() async throws {
        let accountID = "rescan-\(UUID().uuidString)"
        let revision = CredentialRevision()
        let diagnostics = ScanDiagnosticsSpy()
        let controller = LifecycleListController(blocksRoot: true)
        let coordinator = makeCoordinator(diagnostics: diagnostics)
        let factory = makeSessionFactory(
            accountID: accountID, revision: revision, controller: controller
        )

        _ = await coordinator.store(
            accountKey: accountID, displayName: "NAS",
            credentialRevision: revision, sessionFactory: factory
        )
        await controller.waitUntilListing()

        await coordinator.rescan(accountKey: accountID)

        let recorded = await poll {
            diagnostics.records.contains { $0.owner == .rescanSuperseded }
        }
        XCTAssertTrue(recorded, "the superseded pass must record the rescan owner")
        XCTAssertFalse(
            diagnostics.records.contains { $0.owner == .playbackAdmission || $0.owner == .accountInvalidation },
            "no cross-attribution to a different owner"
        )

        await coordinator.invalidate(accountKey: accountID)
    }

    /// A credential rotation replaces the scanner. The superseded (old-revision) pass is
    /// attributed to the credential-change owner and is recorded against the OLD
    /// credential revision — it cannot stamp the replacement generation.
    func testCredentialSupersessionRecordsOldGenerationOwner() async throws {
        let accountID = "cred-\(UUID().uuidString)"
        let revisionOne = CredentialRevision()
        let revisionTwo = CredentialRevision()
        let diagnostics = ScanDiagnosticsSpy()
        let controller = LifecycleListController(blocksRoot: true)
        let coordinator = makeCoordinator(diagnostics: diagnostics)
        let factoryOne = makeSessionFactory(
            accountID: accountID, revision: revisionOne, controller: controller
        )
        let factoryTwo = makeSessionFactory(
            accountID: accountID, revision: revisionTwo, controller: controller
        )

        _ = await coordinator.store(
            accountKey: accountID, displayName: "NAS",
            credentialRevision: revisionOne, sessionFactory: factoryOne
        )
        await controller.waitUntilListing()

        // A new credential revision rotates the scanner, superseding the blocked pass.
        _ = await coordinator.store(
            accountKey: accountID, displayName: "NAS",
            credentialRevision: revisionTwo, sessionFactory: factoryTwo
        )

        let recorded = await poll {
            diagnostics.records.contains {
                $0.owner == .credentialChange && $0.credentialRevision == revisionOne.rawValue
            }
        }
        XCTAssertTrue(
            recorded,
            "the superseded pass must record the credential-change owner against the OLD revision"
        )
        XCTAssertFalse(
            diagnostics.records.contains { $0.credentialRevision == revisionTwo.rawValue },
            "the replacement generation must not appear in a non-completion record"
        )

        await coordinator.invalidate(accountKey: accountID)
    }

    /// Account invalidation during an in-flight scan attributes that scan to the
    /// account-invalidation owner (and — see A7 — retires the arbiter).
    func testAccountInvalidationDuringScanRecordsOwner() async throws {
        let accountID = "invalidate-scan-\(UUID().uuidString)"
        let revision = CredentialRevision()
        let diagnostics = ScanDiagnosticsSpy()
        let controller = LifecycleListController(blocksRoot: true)
        let coordinator = makeCoordinator(diagnostics: diagnostics)
        let factory = makeSessionFactory(
            accountID: accountID, revision: revision, controller: controller
        )

        _ = await coordinator.store(
            accountKey: accountID, displayName: "NAS",
            credentialRevision: revision, sessionFactory: factory
        )
        await controller.waitUntilListing()

        await coordinator.invalidate(accountKey: accountID)

        XCTAssertTrue(
            diagnostics.records.contains { $0.owner == .accountInvalidation },
            "an invalidated in-flight scan must record the account-invalidation owner"
        )
        let count = await coordinator.arbiterCount()
        XCTAssertEqual(count, 0, "invalidation with no leases retires the arbiter")
    }

    /// A completed *partial* pass (a listing failed, so pruning was skipped) still stamps
    /// completion — preserving the approved throttle so a permanently-inaccessible folder
    /// cannot cause a re-scan storm — and is NOT recorded as a cancellation.
    func testCompletedPartialScanStampsCompletionAndCoalesces() async throws {
        let accountID = "partial-\(UUID().uuidString)"
        let revision = CredentialRevision()
        let diagnostics = ScanDiagnosticsSpy()
        let controller = LifecycleListController(
            blocksRoot: false,
            tree: ["": ["Library"]],
            failingDirs: ["Library"]
        )
        let coordinator = makeCoordinator(diagnostics: diagnostics)
        let factory = makeSessionFactory(
            accountID: accountID, revision: revision, controller: controller
        )

        _ = await coordinator.store(
            accountKey: accountID, displayName: "NAS",
            credentialRevision: revision, sessionFactory: factory
        )
        let stamped = await poll { await coordinator.backgroundScanCompletedAt(accountID) != nil }
        XCTAssertTrue(stamped, "a completed partial pass still stamps completion (approved throttle)")
        XCTAssertTrue(
            diagnostics.records.isEmpty,
            "a completed partial pass is not a cancellation — no non-completion record"
        )

        for _ in 0..<5 {
            _ = await coordinator.store(
                accountKey: accountID, displayName: "NAS",
                credentialRevision: revision, sessionFactory: factory
            )
        }
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(controller.rootLists, 1, "partial completion coalesces like a clean pass")

        await coordinator.invalidate(accountKey: accountID)
    }

    // MARK: - A7: arbiter lifecycle retirement

    /// Invalidating an account whose scan already finished (no leases) removes the
    /// arbiter immediately.
    func testInvalidationWithNoLeasesRemovesArbiterImmediately() async throws {
        let accountID = "retire-\(UUID().uuidString)"
        let revision = CredentialRevision()
        let diagnostics = ScanDiagnosticsSpy()
        let controller = LifecycleListController(blocksRoot: false)
        let coordinator = makeCoordinator(diagnostics: diagnostics)
        let factory = makeSessionFactory(
            accountID: accountID, revision: revision, controller: controller
        )

        _ = await coordinator.store(
            accountKey: accountID, displayName: "NAS",
            credentialRevision: revision, sessionFactory: factory
        )
        _ = await poll { await coordinator.backgroundScanCompletedAt(accountID) != nil }
        let before = await coordinator.arbiterCount()
        XCTAssertEqual(before, 1)

        await coordinator.invalidate(accountKey: accountID)
        let after = await coordinator.arbiterCount()
        XCTAssertEqual(after, 0, "invalidation retires the arbiter")
    }

    /// Invalidation while a playback lease is held rejects new admission, waits for the
    /// lease to drain, retires the old arbiter, and permits a fresh generation after.
    func testInvalidationWithHeldPlaybackLeaseWaitsThenRetires() async throws {
        let accountID = "retire-lease-\(UUID().uuidString)"
        let revision = CredentialRevision()
        let diagnostics = ScanDiagnosticsSpy()
        let controller = LifecycleListController(blocksRoot: false)
        let coordinator = makeCoordinator(diagnostics: diagnostics)
        let factory = makeSessionFactory(
            accountID: accountID, revision: revision, controller: controller
        )

        _ = await coordinator.store(
            accountKey: accountID, displayName: "NAS",
            credentialRevision: revision, sessionFactory: factory
        )
        _ = await poll { await coordinator.backgroundScanCompletedAt(accountID) != nil }

        let lease = try await coordinator.acquirePlayback(accountKey: accountID)
        let invalidation = Task { await coordinator.invalidate(accountKey: accountID) }

        // While the lease is held the arbiter is shutting down: it rejects new admission
        // yet remains retained (it must not disappear before the live lease drains).
        try? await Task.sleep(nanoseconds: 80_000_000)
        do {
            _ = try await coordinator.acquirePlayback(accountKey: accountID)
            XCTFail("a shutting-down arbiter must reject new playback admission")
        } catch let error as MediaTransportError {
            XCTAssertEqual(error, .resourceBusy)
        }
        let retainedDuringDrain = await coordinator.arbiterCount()
        XCTAssertEqual(retainedDuringDrain, 1, "arbiter is retained while a live lease drains")

        await lease.releaseAndWait()
        await invalidation.value
        let afterDrain = await coordinator.arbiterCount()
        XCTAssertEqual(afterDrain, 0, "the arbiter retires once the final lease drains")

        // A re-add installs a fresh arbiter generation.
        _ = await coordinator.store(
            accountKey: accountID, displayName: "NAS",
            credentialRevision: revision, sessionFactory: factory
        )
        let reAdded = await coordinator.arbiterCount()
        XCTAssertEqual(reAdded, 1, "re-add after completed invalidation installs a fresh arbiter")

        await coordinator.invalidate(accountKey: accountID)
    }

    /// Many add/invalidate cycles must leave zero retained arbiters (finding A7: no leak).
    func testRepeatedAddInvalidateCyclesLeaveArbiterCountZero() async throws {
        let accountID = "cycles-\(UUID().uuidString)"
        let revision = CredentialRevision()
        let diagnostics = ScanDiagnosticsSpy()
        let controller = LifecycleListController(blocksRoot: false)
        let coordinator = makeCoordinator(diagnostics: diagnostics)
        let factory = makeSessionFactory(
            accountID: accountID, revision: revision, controller: controller
        )

        for _ in 0..<50 {
            _ = await coordinator.store(
                accountKey: accountID, displayName: "NAS",
                credentialRevision: revision, sessionFactory: factory
            )
            await coordinator.invalidate(accountKey: accountID)
        }
        let count = await coordinator.arbiterCount()
        XCTAssertEqual(count, 0, "repeated add/invalidate must not retain arbiters")
    }

    // MARK: - Scanner outcome contracts (drives the coordinator's gating)

    private func scannerTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("plozz-scan-outcome-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testScanReturnsCompletedCleanWhenEveryListingSucceeds() async {
        let store = ShareCatalogStore(accountKey: "clean", directory: scannerTempDir())
        let scanner = ShareScanner(store: store, concurrency: 1, makeLister: {
            ShareScanner.ScanLister(list: { _ in [] }, close: {})
        })
        let outcome = await scanner.scan()
        XCTAssertEqual(outcome, .completedClean)
    }

    func testScanReturnsCompletedPartialWhenAListingFails() async {
        let store = ShareCatalogStore(accountKey: "partial", directory: scannerTempDir())
        let scanner = ShareScanner(store: store, concurrency: 1, makeLister: {
            ShareScanner.ScanLister(
                list: { relativePath in
                    if relativePath.isEmpty {
                        return [try RemoteFileEntry(
                            relativePath: "Library", kind: .directory, modifiedAt: Date()
                        )]
                    }
                    throw MediaTransportError.unsupportedCapability("injected listing failure")
                },
                close: {}
            )
        })
        let outcome = await scanner.scan()
        XCTAssertEqual(outcome, .completedPartial)
    }

    func testScanIfStaleReturnsFreshNoOpWithinInterval() async {
        let store = ShareCatalogStore(accountKey: "throttle", directory: scannerTempDir())
        let scanner = ShareScanner(store: store, concurrency: 1, makeLister: {
            ShareScanner.ScanLister(list: { _ in [] }, close: {})
        })
        let first = await scanner.scan()
        XCTAssertEqual(first, .completedClean)
        let second = await scanner.scanIfStale()
        XCTAssertEqual(second, .freshNoOp, "a recent completed pass throttles the next walk")
    }

    func testScanReturnsInvalidatedAfterInvalidate() async {
        let store = ShareCatalogStore(accountKey: "invalidated", directory: scannerTempDir())
        let scanner = ShareScanner(store: store, concurrency: 1, makeLister: {
            ShareScanner.ScanLister(list: { _ in [] }, close: {})
        })
        await scanner.invalidate()
        let outcome = await scanner.scan()
        XCTAssertEqual(outcome, .invalidated)
    }

    // MARK: - Late cancellation-reason leak (Batch 3 follow-up)

    /// A reason stamped for a task AFTER `recordScanOutcome` already consumed its first
    /// reason (a racing playback/rescan targeting the still-present task) must be
    /// discarded by `clearScanTask`, or it would leak in `pendingCancellationReasons`
    /// forever. Exercised through the real stamp/consume/clear methods.
    func testReasonStampedInRecordClearWindowIsDiscardedOnClear() async {
        let accountID = "reason-leak-\(UUID().uuidString)"
        let taskID = UUID()
        let coordinator = makeCoordinator(diagnostics: ScanDiagnosticsSpy())

        // 1. Playback admission stamps the task's owner before cancelling it.
        await coordinator.stampCancellationReasonForTesting(
            accountID, taskID: taskID, owner: .playbackAdmission
        )
        // 2. recordScanOutcome consumes that first reason.
        let consumed = await coordinator.takeCancellationReasonForTesting(accountID, taskID: taskID)
        XCTAssertEqual(consumed, .playbackAdmission)
        var pending = await coordinator.pendingCancellationReasonCount(accountID)
        XCTAssertEqual(pending, 0, "the consumed reason is gone")

        // 3. A racing action stamps a NEW reason in the record→clear window.
        await coordinator.stampCancellationReasonForTesting(
            accountID, taskID: taskID, owner: .rescanSuperseded
        )
        pending = await coordinator.pendingCancellationReasonCount(accountID)
        XCTAssertEqual(pending, 1, "a late stamp lands while the task is still present")

        // 4. clearScanTask must discard it — otherwise the reason leaks.
        await coordinator.clearScanTaskForTesting(accountID, taskID: taskID)
        pending = await coordinator.pendingCancellationReasonCount(accountID)
        XCTAssertEqual(pending, 0, "clearScanTask discards a reason stamped after consumption")
    }
}
