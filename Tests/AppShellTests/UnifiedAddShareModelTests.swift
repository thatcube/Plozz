import XCTest
import Foundation
import CoreModels
import ProviderShare
import MediaTransportHTTP
import MediaTransportWebDAV
import MediaTransportSFTP
import MediaTransportFTP
import MediaTransportNFS
@testable import FeatureShareOnboarding
@testable import AppShell

@MainActor
final class UnifiedAddShareModelTests: XCTestCase {
    func testSelectingWebDAVUsesSpecificDetectedPort() {
        let model = UnifiedAddShareModel()
        let box = DiscoveredMediaShareBox(
            host: "192.168.68.71",
            displayName: "CubeBoi",
            doors: [
                .init(transport: .smb, port: nil),
                .init(transport: .webDAV, port: 80, scheme: "http"),
                .init(transport: .webDAV, port: 8384, scheme: "http"),
            ]
        )

        model.openConnect(for: box)
        model.applyTransport(.webDAV)

        XCTAssertEqual(model.portText, "8384")
        XCTAssertEqual(model.detectedPorts(for: .webDAV), [80, 8384])
        XCTAssertEqual(model.webDAVScheme, "http")
    }

    func testManualEntryDefaultsToSMBWithoutAutoDetectOption() {
        let model = UnifiedAddShareModel()

        model.openManualConnect()

        XCTAssertEqual(model.selectedTransport, .smb)
        XCTAssertEqual(model.portText, "445")
    }

    func testManualWebDAVWithoutSchemeProbesHTTPSThenHTTP() async {
        let model = UnifiedAddShareModel(
            serviceProbe: HTTPOnlyServiceProbe()
        )
        model.openManualConnect()
        model.applyTransport(.webDAV)
        model.address = "192.168.68.71"
        model.portText = "8384"
        model.username = "user"

        model.connect()
        for _ in 0..<20 where model.webDAVScheme == nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(model.webDAVScheme, "http")
        // Compare the resource, not rendered English — the assertion must survive
        // translation.
        XCTAssertEqual(
            model.connectError,
            "This WebDAV server uses HTTP. Review the security warning, then Connect again."
        )
        XCTAssertNotNil(model.plaintextWarning)
    }

    func testManualWebDAVPathIsTheBrowseBoundary() async {
        let model = UnifiedAddShareModel(
            webDAVProbe: StubWebDAVProbe()
        )
        model.openManualConnect()
        model.applyTransport(.webDAV)
        model.address = "https://nas.local/dav/movies/"

        model.connect()
        for _ in 0..<50 {
            if model.step == .pickLocation { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertEqual(model.currentPath, "/dav/movies")
        XCTAssertFalse(model.canNavigateUp)
    }

    func testBracketedIPv6WebDAVAddressRoundTrips() async {
        let model = UnifiedAddShareModel(
            webDAVProbe: StubWebDAVProbe()
        )
        var configuration: WebDAVShareConfiguration?
        model.onWebDAVConfigured = { configuration = $0 }
        model.openManualConnect()
        model.applyTransport(.webDAV)
        model.address = "https://[2001:db8::1]/dav"

        model.connect()
        for _ in 0..<50 {
            if model.step == .pickLocation { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        model.useCurrentFolder()

        XCTAssertEqual(
            configuration?.baseURL.absoluteString,
            "https://[2001:db8::1]/dav"
        )
    }

    func testExplicitHTTPUsesHTTPDefaultInsteadOfSuggestedHTTPSPort() async {
        let model = UnifiedAddShareModel(
            webDAVProbe: StubWebDAVProbe()
        )
        var configuration: WebDAVShareConfiguration?
        model.onWebDAVConfigured = { configuration = $0 }
        model.openManualConnect()
        model.applyTransport(.webDAV)
        XCTAssertEqual(model.portText, "443")
        model.address = "http://nas.local/dav"

        model.connect()
        for _ in 0..<50 {
            if model.step == .pickLocation { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        model.useCurrentFolder()

        XCTAssertEqual(
            configuration?.baseURL.absoluteString,
            "http://nas.local/dav"
        )
    }

    func testInvalidPortDisablesConnect() {
        let model = UnifiedAddShareModel()
        model.openManualConnect()
        model.address = "nas.local"
        model.portText = "70000"
        XCTAssertFalse(model.canConnect)
        model.portText = "not-a-port"
        XCTAssertFalse(model.canConnect)
    }

    func testChangingProtocolCancelsStaleConnectionResult() async {
        let model = UnifiedAddShareModel(
            webDAVProbe: DelayedWebDAVProbe()
        )
        model.openManualConnect()
        model.applyTransport(.webDAV)
        model.address = "https://nas.local/dav"
        model.connect()

        model.applyTransport(.smb)
        try? await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(model.selectedTransport, .smb)
        XCTAssertEqual(model.step, .connect)
    }

    private struct HTTPOnlyServiceProbe: MediaShareServiceProbing {
        func confirms(
            host: String,
            target: TransportSweepTarget,
            timeout: TimeInterval
        ) async -> Bool {
            target.probe == .webDAVHTTP
        }
    }

    private struct StubWebDAVProbe: WebDAVOnboardingProbing {
        func preflightTrust(url: URL) async -> WebDAVTrustPreflight {
            .systemTrusted
        }

        func validate(
            url: URL,
            credential: WebDAVCredential,
            trust: WebDAVOnboardingTrust
        ) async -> Result<Void, WebDAVOnboardingError> {
            .success(())
        }

        func listFolders(
            url: URL,
            path: String,
            credential: WebDAVCredential,
            trust: WebDAVOnboardingTrust
        ) async -> Result<[WebDAVOnboardingFolder], WebDAVOnboardingError> {
            .success([])
        }
    }

    private struct DelayedWebDAVProbe: WebDAVOnboardingProbing {
        func preflightTrust(url: URL) async -> WebDAVTrustPreflight {
            try? await Task.sleep(nanoseconds: 10_000_000)
            return .systemTrusted
        }

        func validate(
            url: URL,
            credential: WebDAVCredential,
            trust: WebDAVOnboardingTrust
        ) async -> Result<Void, WebDAVOnboardingError> {
            .success(())
        }

        func listFolders(
            url: URL,
            path: String,
            credential: WebDAVCredential,
            trust: WebDAVOnboardingTrust
        ) async -> Result<[WebDAVOnboardingFolder], WebDAVOnboardingError> {
            .success([])
        }
    }

    // MARK: - NFS / SFTP / FTP unified onboarding

    func testNFSListsExportsAndSavesSelectedExport() async {
        let listing = NFSDirectoryListing.success([
            NFSDirectoryItem(name: "/volume1/Media", path: "/volume1/Media"),
            NFSDirectoryItem(name: "/volume1/Backups", path: "/volume1/Backups"),
        ])
        let model = UnifiedAddShareModel(nfsProbe: StubNFSProbe(exports: listing))
        var result: MediaShareOnboardingResult?
        model.onMediaShareConfigured = { result = $0 }

        model.openManualConnect()
        model.applyTransport(.nfs)
        model.address = "192.168.1.5"
        model.connect()

        XCTAssertEqual(model.step, .pickLocation)
        for _ in 0..<50 {
            if model.locationLoad == .loaded { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(model.locations.map(\.path), ["/volume1/Media", "/volume1/Backups"])

        model.displayName = "Movies"
        model.chooseNFSExport("/volume1/Media")
        for _ in 0..<50 {
            if model.currentPath == "/volume1/Media" { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        model.useCurrentFolder()

        guard case let .nfs(config) = result else {
            return XCTFail("expected NFS result, got \(String(describing: result))")
        }
        XCTAssertEqual(config.host, "192.168.1.5")
        XCTAssertEqual(config.exportPath, "/volume1/Media")
        XCTAssertEqual(config.subpath, "")
        XCTAssertEqual(config.displayName, "Movies")
    }

    func testNFSExportCanDrillIntoNestedFolderWithoutChangingMountRoot() async {
        let probe = StubNFSProbe(
            exports: .success([
                NFSDirectoryItem(name: "/volume1/Media", path: "/volume1/Media")
            ]),
            directories: .success([
                NFSDirectoryItem(
                    name: "Movies",
                    path: "/volume1/Media/Movies"
                )
            ])
        )
        let model = UnifiedAddShareModel(nfsProbe: probe)
        var result: MediaShareOnboardingResult?
        model.onMediaShareConfigured = { result = $0 }

        model.openManualConnect()
        model.applyTransport(.nfs)
        model.address = "nas.local"
        model.connect()
        for _ in 0..<50 {
            if model.locationLoad == .loaded { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        model.selectLocation(model.locations[0])
        for _ in 0..<50 {
            if model.currentPath == "/volume1/Media" { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        model.selectLocation(model.locations[0])
        for _ in 0..<50 {
            if model.currentPath == "/volume1/Media/Movies" { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        model.useCurrentFolder()

        guard case let .nfs(config) = result else {
            return XCTFail("expected NFS result, got \(String(describing: result))")
        }
        XCTAssertEqual(config.exportPath, "/volume1/Media")
        XCTAssertEqual(config.subpath, "Movies")
    }

    func testNFSFallsBackToManualExportWhenListingBlocked() async {
        let model = UnifiedAddShareModel(nfsProbe: StubNFSProbe(exports: .permissionDenied))
        var result: MediaShareOnboardingResult?
        model.onMediaShareConfigured = { result = $0 }

        model.openManualConnect()
        model.applyTransport(.nfs)
        model.address = "192.168.1.5"
        model.connect()

        for _ in 0..<50 {
            if case .failed = model.locationLoad { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        guard case .failed = model.locationLoad else {
            return XCTFail("expected failed load, got \(model.locationLoad)")
        }

        // Manual fallback: type the export path, normalized to a leading slash.
        model.manualShare = "volume1/Media"
        model.chooseNFSManualExport()

        guard case let .nfs(config) = result else {
            return XCTFail("expected NFS result, got \(String(describing: result))")
        }
        XCTAssertEqual(config.exportPath, "/volume1/Media")
        XCTAssertEqual(config.subpath, "")
    }

    func testSMBShareCanDrillIntoNestedFolderAndPreservesPathCase() async {
        let probe = StubSMBProbe(
            shares: .success([
                SMBOnboardingLocation(name: "Multimedia", path: "Multimedia")
            ]),
            directories: .success([
                SMBOnboardingLocation(name: "Movies", path: "Movies")
            ])
        )
        let model = UnifiedAddShareModel(smbProbe: probe)
        var draft: ShareDraft?
        model.onSMBConfigured = { draft = $0 }

        model.openManualConnect()
        model.address = "nas.local"
        model.connect()
        for _ in 0..<50 {
            if model.locationLoad == .loaded { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        model.selectLocation(model.locations[0])
        for _ in 0..<50 {
            if model.currentPath == "Multimedia" { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        model.selectLocation(model.locations[0])
        for _ in 0..<50 {
            if model.currentPath == "Multimedia/Movies" { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        model.useCurrentFolder()

        XCTAssertEqual(draft?.share, "Multimedia")
        XCTAssertEqual(draft?.subpath, "Movies")
    }

    func testEmptySMBEnumerationStillOffersManualRootEntry() async {
        let model = UnifiedAddShareModel(smbProbe: StubSMBProbe())
        model.openManualConnect()
        model.address = "nas.local"
        model.connect()
        for _ in 0..<50 {
            if model.locationLoad == .loaded { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertTrue(model.locations.isEmpty)
        XCTAssertTrue(model.showsManualRootEntry)
    }

    func testRetryUsesInitiallyEnteredSMBNestedRoot() async {
        let probe = FlakySMBProbe()
        let model = UnifiedAddShareModel(smbProbe: probe)

        model.openManualConnect()
        model.address = "smb://nas.local/Multimedia/Movies"
        model.connect()
        for _ in 0..<50 {
            if model.locationLoad == .unreachable { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertEqual(model.currentPath, "Multimedia/Movies")
        model.retryLocations()
        for _ in 0..<50 {
            if model.locationLoad == .loaded { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertEqual(model.locationLoad, .loaded)
        XCTAssertEqual(probe.directoryCallCount, 2)
        XCTAssertFalse(model.canNavigateUp)
    }

    func testFTPAnonymousBuildsPlainFTPURL() async {
        let model = UnifiedAddShareModel(ftpProbe: StubFTPProbe())
        var result: MediaShareOnboardingResult?
        model.onMediaShareConfigured = { result = $0 }

        model.openManualConnect()
        model.applyTransport(.ftp)
        model.address = "ftp://192.168.1.5/pub"
        model.connect()

        for _ in 0..<50 {
            if model.step == .pickLocation { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(model.step, .pickLocation)
        XCTAssertEqual(model.confirmedPath, "/pub")
        model.chooseFilesystemRoot()

        guard case let .ftp(config) = result else {
            return XCTFail("expected FTP result, got \(String(describing: result))")
        }
        XCTAssertEqual(config.baseURL.absoluteString, "ftp://192.168.1.5/pub")
        XCTAssertEqual(config.auth, .anonymous)
        XCTAssertNil(config.trustPin)
    }

    func testFTPBadCredentialsStayOnConnectWithError() async {
        let model = UnifiedAddShareModel(ftpProbe: StubFTPProbe(listing: .authenticationFailed))
        var result: MediaShareOnboardingResult?
        model.onMediaShareConfigured = { result = $0 }

        model.openManualConnect()
        model.applyTransport(.ftp)
        model.address = "192.168.1.5"
        model.username = "bob"
        model.password = "wrong"
        model.connect()

        for _ in 0..<50 {
            if model.connectError != nil { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        // Must stay on the Connect page with a credential error, not advance.
        XCTAssertEqual(model.step, .connect)
        XCTAssertEqual(model.connectError, "That username or password was rejected.")
        XCTAssertNil(result)
    }

    func testFTPSPort990BuildsImplicitTLSURLWithPassword() async {
        let model = UnifiedAddShareModel(ftpProbe: StubFTPProbe())
        var result: MediaShareOnboardingResult?
        model.onMediaShareConfigured = { result = $0 }

        model.openManualConnect()
        model.applyTransport(.ftp)
        model.address = "192.168.1.5"
        model.portText = "990"
        model.username = "bob"
        model.password = "secret"
        model.connect()
        for _ in 0..<50 {
            if model.locationLoad == .loaded { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        model.chooseFilesystemRoot()

        guard case let .ftp(config) = result else {
            return XCTFail("expected FTP result, got \(String(describing: result))")
        }
        XCTAssertEqual(config.baseURL.scheme, "ftps")
        XCTAssertEqual(config.auth, .password(username: "bob", password: "secret"))
    }

    func testFTPFolderBrowsingDrillsIntoSubfolderAndSaves() async {
        let listing = FTPDirectoryListing.success([
            FTPDirectoryItem(name: "Movies", path: "/Movies"),
            FTPDirectoryItem(name: "TV", path: "/TV"),
        ])
        let model = UnifiedAddShareModel(ftpProbe: StubFTPProbe(listing: listing))
        var result: MediaShareOnboardingResult?
        model.onMediaShareConfigured = { result = $0 }

        model.openManualConnect()
        model.applyTransport(.ftp)
        model.address = "192.168.1.5"
        model.connect()

        for _ in 0..<50 {
            if model.locationLoad == .loaded { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(model.locations.map(\.name), ["Movies", "TV"])

        await model.loadFTPFolders(path: "/Movies")
        XCTAssertEqual(model.currentPath, "/Movies")
        model.chooseFilesystemRoot()

        guard case let .ftp(config) = result else {
            return XCTFail("expected FTP result, got \(String(describing: result))")
        }
        XCTAssertEqual(config.baseURL.absoluteString, "ftp://192.168.1.5/Movies")
    }

    func testSFTPCapturesHostKeyThenVerifiesThenSaves() async {
        let pin = Data(repeating: 0x11, count: 32)
        let model = UnifiedAddShareModel(sftpProbe: StubSFTPProbe(result: .success(hostKeySHA256: pin)))
        var result: MediaShareOnboardingResult?
        model.onMediaShareConfigured = { result = $0 }

        model.openManualConnect()
        model.applyTransport(.sftp)
        model.address = "192.168.1.5/media"
        model.username = "brandon"
        model.password = "hunter2"
        model.connect()

        for _ in 0..<50 {
            if case .verifyTrust = model.step { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        guard case .verifyTrust(let sha256) = model.step else {
            return XCTFail("expected verifyTrust, got \(model.step)")
        }
        XCTAssertEqual(sha256, pin)

        model.approveTrust()
        XCTAssertEqual(model.step, .pickLocation)
        for _ in 0..<50 {
            if model.confirmedPath == "/media" { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(model.confirmedPath, "/media")

        model.chooseFilesystemRoot()
        guard case let .sftp(config) = result else {
            return XCTFail("expected SFTP result, got \(String(describing: result))")
        }
        XCTAssertEqual(config.host, "192.168.1.5")
        XCTAssertEqual(config.path, "/media")
        XCTAssertEqual(config.username, "brandon")
        XCTAssertEqual(config.password, "hunter2")
        XCTAssertEqual(config.hostKeyPin.bytes, pin)
    }

    func testSFTPFolderBrowsingDrillsIntoSubfolderAndSaves() async {
        let pin = Data(repeating: 0x33, count: 32)
        let listing = SFTPDirectoryListing.success([
            SFTPDirectoryItem(name: "Movies", path: "/Movies"),
            SFTPDirectoryItem(name: "TV", path: "/TV"),
        ])
        let model = UnifiedAddShareModel(
            sftpProbe: StubSFTPProbe(result: .success(hostKeySHA256: pin), listing: listing)
        )
        var result: MediaShareOnboardingResult?
        model.onMediaShareConfigured = { result = $0 }

        model.openManualConnect()
        model.applyTransport(.sftp)
        model.address = "192.168.1.5"
        model.username = "brandon"
        model.password = "hunter2"
        model.connect()

        for _ in 0..<50 {
            if case .verifyTrust = model.step { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        model.approveTrust()
        for _ in 0..<50 {
            if model.locationLoad == .loaded { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(model.locations.map(\.name), ["Movies", "TV"])
        XCTAssertTrue(model.locations.allSatisfy(\.isBrowsable))

        // Drill into Movies, then use it as the share root.
        await model.loadSFTPFolders(path: "/Movies")
        XCTAssertEqual(model.currentPath, "/Movies")
        model.chooseFilesystemRoot()

        guard case let .sftp(config) = result else {
            return XCTFail("expected SFTP result, got \(String(describing: result))")
        }
        XCTAssertEqual(config.path, "/Movies")
    }

    func testSFTPAuthFailureSurfacesErrorAndStaysOnConnect() async {
        let model = UnifiedAddShareModel(sftpProbe: StubSFTPProbe(result: .authenticationFailed))
        var result: MediaShareOnboardingResult?
        model.onMediaShareConfigured = { result = $0 }

        model.openManualConnect()
        model.applyTransport(.sftp)
        model.address = "192.168.1.5"
        model.username = "brandon"
        model.password = "wrong"
        model.connect()

        for _ in 0..<50 {
            if model.connectError != nil { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertNotNil(model.connectError)
        XCTAssertEqual(model.step, .connect)
        XCTAssertNil(result)
    }

    func testRejectingSFTPHostKeyDiscardsPin() async {
        let pin = Data(repeating: 0x22, count: 32)
        let model = UnifiedAddShareModel(sftpProbe: StubSFTPProbe(result: .success(hostKeySHA256: pin)))
        var result: MediaShareOnboardingResult?
        model.onMediaShareConfigured = { result = $0 }

        model.openManualConnect()
        model.applyTransport(.sftp)
        model.address = "192.168.1.5/media"
        model.username = "brandon"
        model.password = "hunter2"
        model.connect()

        for _ in 0..<50 {
            if case .verifyTrust = model.step { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        model.rejectTrust()
        XCTAssertEqual(model.step, .connect)
        // With the pin discarded, a save must not fabricate an SFTP config.
        model.chooseFilesystemRoot()
        XCTAssertNil(result)
    }

    private struct StubSFTPProbe: SFTPOnboardingProbing {
        let result: SFTPOnboardingProbeResult
        var listing: SFTPDirectoryListing = .success([])
        func captureHostKey(
            host: String,
            port: Int
        ) async -> SFTPOnboardingProbeResult {
            result
        }
        func listDirectories(
            host: String,
            port: Int,
            username: String,
            password: String,
            hostKeySHA256: Data,
            path: String
        ) async -> SFTPDirectoryListing {
            listing
        }
    }

    private struct StubFTPProbe: FTPOnboardingProbing {
        var listing: FTPDirectoryListing = .success([])
        func listDirectories(
            host: String,
            port: Int?,
            isImplicitTLS: Bool,
            username: String,
            password: String,
            trustPinSHA256: Data?,
            path: String
        ) async -> FTPDirectoryListing {
            listing
        }
    }

    private struct StubNFSProbe: NFSOnboardingProbing {
        var exports: NFSDirectoryListing = .success([])
        var directories: NFSDirectoryListing = .success([])
        func listExports(host: String, port: Int?) async -> NFSDirectoryListing {
            exports
        }
        func listDirectories(
            host: String,
            port: Int?,
            exportPath: String,
            relativePath: String
        ) async -> NFSDirectoryListing {
            directories
        }
    }

    private struct StubSMBProbe: SMBOnboardingProbing {
        var shares: SMBOnboardingListing = .success([])
        var directories: SMBOnboardingListing = .success([])

        func listShares(
            host: String,
            port: Int?,
            username: String,
            password: String
        ) async -> SMBOnboardingListing {
            shares
        }

        func listDirectories(
            host: String,
            port: Int?,
            share: String,
            username: String,
            password: String,
            relativePath: String
        ) async -> SMBOnboardingListing {
            directories
        }
    }

    private final class FlakySMBProbe: SMBOnboardingProbing, @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0

        var directoryCallCount: Int {
            lock.withLock { calls }
        }

        func listShares(
            host: String,
            port: Int?,
            username: String,
            password: String
        ) async -> SMBOnboardingListing {
            .success([])
        }

        func listDirectories(
            host: String,
            port: Int?,
            share: String,
            username: String,
            password: String,
            relativePath: String
        ) async -> SMBOnboardingListing {
            let call = lock.withLock {
                calls += 1
                return calls
            }
            return call == 1 ? .unreachable : .success([])
        }
    }
}
