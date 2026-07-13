import XCTest
@testable import MediaTransportHTTP

final class CredentialPreflightTests: XCTestCase {
    private let httpOrigin = TransportOrigin(url: URL(string: "http://nas.local:8080/")!)!
    private let httpsOrigin = TransportOrigin(url: URL(string: "https://nas.example.com/")!)!

    func testAnonymousAllowedOverHTTP() {
        XCTAssertNil(CredentialPreflight.validate(credential: .anonymous, origin: httpOrigin))
    }

    func testAnonymousAllowedOverHTTPS() {
        XCTAssertNil(CredentialPreflight.validate(credential: .anonymous, origin: httpsOrigin))
    }

    func testPasswordAllowedOverHTTP_automaticPolicy() {
        // Plozz permits credentials over plain HTTP for a LAN media share (the
        // onboarding UI warns); HTTPS stays the recommended default.
        let credential = WebDAVCredential.password(username: "u", password: "p", policy: .automatic)
        XCTAssertNil(CredentialPreflight.validate(credential: credential, origin: httpOrigin))
    }

    func testPasswordAllowedOverHTTP_digestOnlyPolicy() {
        let credential = WebDAVCredential.password(username: "u", password: "p", policy: .digestOnly)
        XCTAssertNil(CredentialPreflight.validate(credential: credential, origin: httpOrigin))
    }

    func testPasswordAllowedOverHTTP_basicAllowedPolicy() {
        let credential = WebDAVCredential.password(username: "u", password: "p", policy: .basicAllowed)
        XCTAssertNil(CredentialPreflight.validate(credential: credential, origin: httpOrigin))
    }

    func testPasswordAllowedOverHTTPS() {
        let credential = WebDAVCredential.password(username: "u", password: "p", policy: .automatic)
        XCTAssertNil(CredentialPreflight.validate(credential: credential, origin: httpsOrigin))
    }

    func testBearerTokenAllowedOverHTTP() {
        let credential = WebDAVCredential.bearerToken("secret-bearer-token")
        XCTAssertNil(CredentialPreflight.validate(credential: credential, origin: httpOrigin))
    }

    func testBearerTokenAllowedOverHTTPS() {
        let credential = WebDAVCredential.bearerToken("secret-bearer-token")
        XCTAssertNil(CredentialPreflight.validate(credential: credential, origin: httpsOrigin))
    }

    // MARK: - Password auth scheme policy

    func testDigestOnlyPermitsDigestNotBasic() {
        XCTAssertTrue(PasswordAuthPolicy.digestOnly.permits(.digest))
        XCTAssertFalse(PasswordAuthPolicy.digestOnly.permits(.basic))
    }

    func testBasicAllowedPermitsBothSchemes() {
        XCTAssertTrue(PasswordAuthPolicy.basicAllowed.permits(.digest))
        XCTAssertTrue(PasswordAuthPolicy.basicAllowed.permits(.basic))
    }

    func testAutomaticPermitsBothSchemes() {
        XCTAssertTrue(PasswordAuthPolicy.automatic.permits(.digest))
        XCTAssertTrue(PasswordAuthPolicy.automatic.permits(.basic))
    }

    // MARK: - Redacted descriptions

    func testPasswordCredentialDescriptionNeverContainsThePassword() {
        let credential = WebDAVCredential.password(username: "brandon", password: "super-secret-password", policy: .automatic)
        XCTAssertFalse(credential.description.contains("super-secret-password"))
        XCTAssertFalse(credential.description.contains("brandon"))
    }

    func testBearerCredentialDescriptionNeverContainsTheToken() {
        let credential = WebDAVCredential.bearerToken("super-secret-bearer-token")
        XCTAssertFalse(credential.description.contains("super-secret-bearer-token"))
    }
}
