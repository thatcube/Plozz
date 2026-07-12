import XCTest
@testable import MediaTransportHTTP

final class TransportSessionDelegateTests: XCTestCase {
    private let origin = TransportOrigin(url: URL(string: "https://nas.example.com/")!)!

    func testDigestChallengeUsesNonPersistentPasswordCredential() {
        let decision = evaluateChallenge(
            authenticationMethod: NSURLAuthenticationMethodHTTPDigest,
            credential: .password(username: "user", password: "secret", policy: .automatic)
        )

        guard case .useCredential(let credential) = decision else {
            return XCTFail("expected useCredential")
        }
        XCTAssertEqual(credential.user, "user")
        XCTAssertEqual(credential.password, "secret")
        XCTAssertEqual(credential.persistence, .none)
    }

    func testDigestOnlyRejectsBasicChallenge() {
        let decision = evaluateChallenge(
            authenticationMethod: NSURLAuthenticationMethodHTTPBasic,
            credential: .password(username: "user", password: "secret", policy: .digestOnly)
        )

        guard case .reject(.authenticationSchemeNotPermitted(scheme: "basic")) = decision else {
            return XCTFail("expected Basic to be rejected")
        }
    }

    func testBasicAllowedAnswersBasicChallenge() {
        let decision = evaluateChallenge(
            authenticationMethod: NSURLAuthenticationMethodHTTPBasic,
            credential: .password(username: "user", password: "secret", policy: .basicAllowed)
        )

        guard case .useCredential(let credential) = decision else {
            return XCTFail("expected useCredential")
        }
        XCTAssertEqual(credential.persistence, .none)
    }

    func testRejectedCredentialIsNotRetried() {
        let decision = evaluateChallenge(
            authenticationMethod: NSURLAuthenticationMethodHTTPDigest,
            credential: .password(username: "user", password: "secret", policy: .automatic),
            previousFailureCount: 1
        )

        guard case .reject(.authenticationFailed) = decision else {
            return XCTFail("expected authenticationFailed")
        }
    }

    func testChallengeForDifferentOriginIsRejected() {
        let decision = evaluateChallenge(
            host: "attacker.example.net",
            authenticationMethod: NSURLAuthenticationMethodHTTPDigest,
            credential: .password(username: "user", password: "secret", policy: .automatic)
        )

        guard case .reject(.invalidOrigin) = decision else {
            return XCTFail("expected invalidOrigin")
        }
    }

    func testAnonymousCredentialDoesNotAnswerPasswordChallenge() {
        let decision = evaluateChallenge(
            authenticationMethod: NSURLAuthenticationMethodHTTPBasic,
            credential: .anonymous
        )

        guard case .performDefaultHandling = decision else {
            return XCTFail("expected performDefaultHandling")
        }
    }

    private func evaluateChallenge(
        host: String = "nas.example.com",
        authenticationMethod: String,
        credential: WebDAVCredential,
        previousFailureCount: Int = 0
    ) -> PasswordChallengeDecision {
        let delegate = TransportSessionDelegate(
            credential: credential,
            trustPolicy: .system,
            origin: origin
        )
        let protectionSpace = URLProtectionSpace(
            host: host,
            port: 443,
            protocol: "https",
            realm: "test",
            authenticationMethod: authenticationMethod
        )
        return delegate.passwordChallengeDecision(
            space: protectionSpace,
            previousFailureCount: previousFailureCount
        )
    }
}
