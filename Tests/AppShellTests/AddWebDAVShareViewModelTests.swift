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

    func testFolderPathWithSpaceProducesValidEncodedURLWithoutCrashing() async {
        // A percent-ENCODED folder path (as the real probe emits) must round-trip
        // to a valid baseURL. Assigning a DECODED path here previously crashed
        // (URLComponents.percentEncodedPath rejects a space) — regression lock.
        let probe = StubProbe()
        probe.preflightResult = .systemTrusted
        probe.validateResult = .success(())
        probe.foldersResult = .success([
            WebDAVOnboardingFolder(path: "/dav/My%20Movies", name: "My Movies")
        ])
        let vm = AddWebDAVShareViewModel(probe: probe)
        vm.address = "https://nas.example.com/dav"
        vm.authMode = .anonymous
        await vm.connect()
        await vm.loadFolders(at: "/dav/My%20Movies")
        vm.useCurrentFolder()
        guard case .done(let config) = vm.step else { return XCTFail("expected done") }
        XCTAssertEqual(config.baseURL.absoluteString, "https://nas.example.com/dav/My%20Movies")
    }

    // MARK: - Probe path re-encoder

    func testProbeReEncodesDecodedPathSegments() {
        XCTAssertEqual(
            WebDAVOnboardingProbe.percentEncodedPath(fromDecoded: "/dav/My Movies"),
            "/dav/My%20Movies"
        )
        // A literal percent and other reserved characters are encoded, not
        // reinterpreted — so a folder literally named "50%" or "a?b" round-trips.
        XCTAssertEqual(WebDAVOnboardingProbe.percentEncodedPath(fromDecoded: "/50%"), "/50%25")
        XCTAssertEqual(WebDAVOnboardingProbe.percentEncodedPath(fromDecoded: "/a?b"), "/a%3Fb")
        XCTAssertEqual(WebDAVOnboardingProbe.percentEncodedPath(fromDecoded: "/"), "/")
        // Unreserved characters are left literal.
        XCTAssertEqual(WebDAVOnboardingProbe.percentEncodedPath(fromDecoded: "/a-b_c.d~e"), "/a-b_c.d~e")
    }

    // MARK: - Stale-input protection (Sol #1) + request ordering (Sol #5)

    func testEditingFieldsDuringTrustApprovalDoesNotChangeTheApprovedAttempt() async {
        let probe = StubProbe()
        probe.preflightResult = .needsApproval(sha256: Data(repeating: 0x09, count: 32))
        probe.validateResult = .success(())
        probe.foldersResult = .success([])
        let vm = AddWebDAVShareViewModel(probe: probe)
        vm.address = "https://original.example.com/dav"
        vm.authMode = .bearer
        vm.bearerToken = "original-token"
        await vm.connect() // → confirmTrust (snapshot captured)

        // User edits the fields while the trust-approval card is showing.
        vm.address = "https://evil.example.com/other"
        vm.bearerToken = "new-token"
        await vm.approveTrust()

        // Validate must have used the ORIGINAL snapshot, not the edited fields.
        XCTAssertEqual(probe.lastValidateURL?.host, "original.example.com")
        XCTAssertEqual(probe.lastValidateBearer, "original-token")

        vm.useCurrentFolder()
        guard case .done(let config) = vm.step else { return XCTFail("expected done") }
        XCTAssertEqual(config.baseURL.host, "original.example.com")
        guard case .bearer(let token) = config.auth else { return XCTFail("expected bearer") }
        XCTAssertEqual(token, "original-token")
    }

    func testOutOfOrderFolderResponsesDoNotOverwriteNewerNavigation() async {
        let probe = GatedStubProbe()
        let vm = AddWebDAVShareViewModel(probe: probe)
        vm.address = "https://nas.example.com/"
        vm.authMode = .anonymous
        // connect() → validate → first loadFolders("/"): release both so we reach browsing.
        async let connected: Void = vm.connect()
        await probe.release() // validate
        await probe.release() // initial loadFolders("/")
        await connected
        XCTAssertEqual(vm.currentPath, "/")

        await probe.setFolders(["/a": [], "/b": []])
        // Start the older navigation (/a) and wait until it's at the gate so its
        // generation is captured BEFORE the newer (/b) starts — deterministic.
        async let navA: Void = vm.loadFolders(at: "/a")
        await probe.waitForWaiters(1)
        async let navB: Void = vm.loadFolders(at: "/b")
        await probe.waitForWaiters(2)
        // Release the NEWER (/b) first, then the older (/a): the stale /a response
        // must be ignored, leaving currentPath at /b.
        await probe.releaseNewestFirst()
        await navA
        await navB
        XCTAssertEqual(vm.currentPath, "/b", "a superseded folder response must not overwrite newer navigation")
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
    private(set) var lastValidateURL: URL?
    private(set) var lastValidateBearer: String?

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
        lastValidateURL = url
        if case .bearerToken(let token) = credential { lastValidateBearer = token }
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

/// A probe whose calls block until explicitly released, so a test can control
/// the completion ORDER of overlapping requests.
private actor GatedStubProbe: WebDAVOnboardingProbing {
    private var foldersByPath: [String: [WebDAVOnboardingFolder]] = [:]
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func setFolders(_ folders: [String: [WebDAVOnboardingFolder]]) {
        foldersByPath = folders
    }

    nonisolated func preflightTrust(url: URL) async -> WebDAVTrustPreflight { .systemTrusted }

    func validate(
        url: URL,
        credential: WebDAVCredential,
        trust: WebDAVOnboardingTrust
    ) async -> Result<Void, WebDAVOnboardingError> {
        await gate()
        return .success(())
    }

    func listFolders(
        url: URL,
        path: String,
        credential: WebDAVCredential,
        trust: WebDAVOnboardingTrust
    ) async -> Result<[WebDAVOnboardingFolder], WebDAVOnboardingError> {
        await gate()
        return .success(foldersByPath[path] ?? [])
    }

    private func gate() async {
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func waitForWaiters(_ count: Int) async {
        while waiters.count < count { await Task.yield() }
    }

    /// Releases the oldest pending call (FIFO).
    func release() async {
        while waiters.isEmpty { await Task.yield() }
        waiters.removeFirst().resume()
    }

    /// With (at least) two calls pending, releases the NEWEST first, then the oldest.
    func releaseNewestFirst() async {
        while waiters.count < 2 { await Task.yield() }
        let newest = waiters.removeLast()
        let oldest = waiters.removeFirst()
        newest.resume()
        await Task.yield()
        oldest.resume()
    }
}
#endif
