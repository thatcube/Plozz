#if canImport(SwiftUI)
import CoreModels
import FeatureAuth
import Foundation
import MediaTransportHTTP
@testable import AppShell
import XCTest

@MainActor
final class AddWebDAVShareViewModelTests: XCTestCase {

    // MARK: - Address validation + cleartext guard

    func testInvalidAddressSurfacesError() async {
        let vm = AddWebDAVShareViewModel(probe: StubProbe())
        vm.address = "   "
        await vm.connect()
        XCTAssertEqual(vm.step, .enterAddress)
        XCTAssertNotNil(vm.errorMessage)
    }

    func testPasswordOverPlainHTTPIsRejectedBeforeAnyRequest() async {
        let probe = StubProbe()
        let vm = AddWebDAVShareViewModel(probe: probe)
        vm.address = "http://nas.local/dav"
        vm.authMode = .usernamePassword
        vm.username = "u"; vm.password = "p"
        await vm.connect()
        XCTAssertEqual(vm.step, .enterAddress)
        XCTAssertNotNil(vm.errorMessage)
        XCTAssertEqual(probe.preflightCount, 0)
        XCTAssertEqual(probe.validateCount, 0, "no request may be made for a cleartext credential")
    }

    func testAnonymousOverPlainHTTPProceeds() async {
        let probe = StubProbe()
        probe.validateResult = .success(())
        probe.foldersResult = .success([])
        let vm = AddWebDAVShareViewModel(probe: probe)
        vm.address = "http://nas.local/pub"
        vm.authMode = .anonymous
        await vm.connect()
        XCTAssertEqual(vm.step, .browsing)
        XCTAssertEqual(probe.preflightCount, 0, "http needs no TLS preflight")
    }

    // MARK: - HTTPS trust preflight

    func testSystemTrustedHTTPSBrowsesWithoutApproval() async {
        let probe = StubProbe()
        probe.preflightResult = .systemTrusted
        probe.validateResult = .success(())
        probe.foldersResult = .success([folder("/dav/Movies")])
        let vm = AddWebDAVShareViewModel(probe: probe)
        vm.address = "https://nas.example.com/dav"
        await vm.connect()
        XCTAssertEqual(vm.step, .browsing)
        XCTAssertEqual(vm.folders.map(\.name), ["Movies"])
    }

    func testSelfSignedHTTPSRequiresExplicitApproval() async {
        let pin = Data(repeating: 0xAB, count: 32)
        let probe = StubProbe()
        probe.preflightResult = .needsApproval(sha256: pin)
        probe.validateResult = .success(())
        probe.foldersResult = .success([])
        let vm = AddWebDAVShareViewModel(probe: probe)
        vm.address = "https://nas.example.com/dav"
        await vm.connect()

        // Must stop at the trust-approval gate; no validate yet.
        XCTAssertEqual(vm.step, .confirmTrust(sha256: pin))
        XCTAssertEqual(probe.validateCount, 0, "must not send credentials before the cert is approved")

        await vm.approveTrust()
        XCTAssertEqual(vm.step, .browsing)
        XCTAssertEqual(probe.validateCount, 1)
    }

    func testRejectingTrustReturnsToAddress() async {
        let probe = StubProbe()
        probe.preflightResult = .needsApproval(sha256: Data(repeating: 0x01, count: 32))
        let vm = AddWebDAVShareViewModel(probe: probe)
        vm.address = "https://nas.example.com/dav"
        await vm.connect()
        vm.rejectTrust()
        XCTAssertEqual(vm.step, .enterAddress)
    }

    func testUnreachablePreflightSurfacesError() async {
        let probe = StubProbe()
        probe.preflightResult = .unreachable
        let vm = AddWebDAVShareViewModel(probe: probe)
        vm.address = "https://nas.example.com/dav"
        await vm.connect()
        XCTAssertEqual(vm.step, .enterAddress)
        XCTAssertNotNil(vm.errorMessage)
    }

    // MARK: - Validate failure

    func testAuthFailureReturnsToAddressWithError() async {
        let probe = StubProbe()
        probe.preflightResult = .systemTrusted
        probe.validateResult = .failure(.authenticationFailed)
        let vm = AddWebDAVShareViewModel(probe: probe)
        vm.address = "https://nas.example.com/dav"
        vm.authMode = .usernamePassword
        vm.username = "u"; vm.password = "bad"
        await vm.connect()
        XCTAssertEqual(vm.step, .enterAddress)
        XCTAssertNotNil(vm.errorMessage)
    }

    // MARK: - Folder browse + confirm

    func testUseCurrentFolderProducesConfigWithApprovedPin() async {
        let pin = Data(repeating: 0xCD, count: 32)
        let probe = StubProbe()
        probe.preflightResult = .needsApproval(sha256: pin)
        probe.validateResult = .success(())
        probe.foldersResult = .success([folder("/dav/Movies")])
        let vm = AddWebDAVShareViewModel(probe: probe)
        vm.address = "https://nas.example.com/dav"
        vm.authMode = .bearer
        vm.bearerToken = "tok"
        vm.displayName = "My DAV"
        await vm.connect()
        await vm.approveTrust()
        // Navigate into the Movies folder, then use it.
        await vm.loadFolders(at: "/dav/Movies")
        XCTAssertEqual(vm.currentPath, "/dav/Movies")
        vm.useCurrentFolder()

        guard case .done(let config) = vm.step else {
            return XCTFail("expected done step")
        }
        XCTAssertEqual(config.baseURL.absoluteString, "https://nas.example.com/dav/Movies")
        XCTAssertEqual(config.displayName, "My DAV")
        XCTAssertEqual(config.trustPin?.bytes, pin)
        guard case .bearer(let token) = config.auth else {
            return XCTFail("expected bearer auth")
        }
        XCTAssertEqual(token, "tok")
    }

    func testUseRootFolderProducesOriginBaseURL() async {
        let probe = StubProbe()
        probe.preflightResult = .systemTrusted
        probe.validateResult = .success(())
        probe.foldersResult = .success([])
        let vm = AddWebDAVShareViewModel(probe: probe)
        vm.address = "https://nas.example.com:8443/"
        vm.authMode = .anonymous
        await vm.connect()
        vm.useCurrentFolder()
        guard case .done(let config) = vm.step else { return XCTFail("expected done") }
        XCTAssertEqual(config.baseURL.absoluteString, "https://nas.example.com:8443")
        XCTAssertNil(config.trustPin)
    }

    // MARK: - Helpers

    private func folder(_ path: String) -> WebDAVOnboardingFolder {
        WebDAVOnboardingFolder(path: path, name: path.split(separator: "/").last.map(String.init) ?? path)
    }
}

private final class StubProbe: WebDAVOnboardingProbing, @unchecked Sendable {
    var preflightResult: WebDAVTrustPreflight = .systemTrusted
    var validateResult: Result<Void, WebDAVOnboardingError> = .success(())
    var foldersResult: Result<[WebDAVOnboardingFolder], WebDAVOnboardingError> = .success([])

    private(set) var preflightCount = 0
    private(set) var validateCount = 0
    private(set) var listCount = 0

    func preflightTrust(url: URL) async -> WebDAVTrustPreflight {
        preflightCount += 1
        return preflightResult
    }

    func validate(
        url: URL,
        credential: WebDAVCredential,
        trust: WebDAVOnboardingTrust
    ) async -> Result<Void, WebDAVOnboardingError> {
        validateCount += 1
        return validateResult
    }

    func listFolders(
        url: URL,
        path: String,
        credential: WebDAVCredential,
        trust: WebDAVOnboardingTrust
    ) async -> Result<[WebDAVOnboardingFolder], WebDAVOnboardingError> {
        listCount += 1
        return foldersResult
    }
}
#endif
