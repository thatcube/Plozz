import XCTest
import Foundation
import CoreModels
import ProviderShare
import MediaTransportSFTP
import MediaTransportFTP
import MediaTransportNFS
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
        XCTAssertTrue(model.connectError?.contains("uses HTTP") == true)
        XCTAssertNotNil(model.plaintextWarning)
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

        guard case let .nfs(config) = result else {
            return XCTFail("expected NFS result, got \(String(describing: result))")
        }
        XCTAssertEqual(config.host, "192.168.1.5")
        XCTAssertEqual(config.exportPath, "/volume1/Media")
        XCTAssertEqual(config.displayName, "Movies")
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
    }

    func testFTPAnonymousBuildsPlainFTPURL() async {
        let model = UnifiedAddShareModel(ftpProbe: StubFTPProbe())
        var result: MediaShareOnboardingResult?
        model.onMediaShareConfigured = { result = $0 }

        model.openManualConnect()
        model.applyTransport(.ftp)
        model.address = "ftp://192.168.1.5/pub"
        model.connect()

        XCTAssertEqual(model.step, .pickLocation)
        for _ in 0..<50 {
            if model.confirmedPath == "/pub" { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        model.chooseFilesystemRoot()

        guard case let .ftp(config) = result else {
            return XCTFail("expected FTP result, got \(String(describing: result))")
        }
        XCTAssertEqual(config.baseURL.absoluteString, "ftp://192.168.1.5/pub")
        XCTAssertEqual(config.auth, .anonymous)
        XCTAssertNil(config.trustPin)
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
            port: Int,
            username: String,
            password: String
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
}
