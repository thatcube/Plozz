import XCTest
@testable import MediaTransportHTTP

final class TransportTrustTests: XCTestCase {
    private let leafA = Data("leaf-certificate-a-der-bytes".utf8)
    private let leafB = Data("leaf-certificate-b-der-bytes-different".utf8)

    func testSHA256IsDeterministicForSameInput() {
        let first = LeafCertificateTrust.sha256(ofLeafCertificateDER: leafA)
        let second = LeafCertificateTrust.sha256(ofLeafCertificateDER: leafA)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 32, "SHA-256 digest must be 32 bytes")
    }

    func testSHA256DiffersForDifferentInput() {
        let a = LeafCertificateTrust.sha256(ofLeafCertificateDER: leafA)
        let b = LeafCertificateTrust.sha256(ofLeafCertificateDER: leafB)
        XCTAssertNotEqual(a, b)
    }

    func testPinnedLeafMatchesExactDERSucceeds() {
        let pinned = LeafCertificateTrust.sha256(ofLeafCertificateDER: leafA)
        let policy = TrustPolicy.pinnedLeaf(sha256: pinned, revision: UUID())
        XCTAssertNil(LeafCertificateTrust.evaluatePinnedLeaf(leafA, against: policy))
    }

    func testPinnedLeafMismatchFailsClosed() {
        let pinned = LeafCertificateTrust.sha256(ofLeafCertificateDER: leafA)
        let policy = TrustPolicy.pinnedLeaf(sha256: pinned, revision: UUID())
        XCTAssertEqual(LeafCertificateTrust.evaluatePinnedLeaf(leafB, against: policy), .trustPinMismatch)
    }

    func testDifferentPinRevisionsWithSameHashAreStillEqualPolicyValues() {
        // Equatable conformance on TrustPolicy compares all fields,
        // including revision — two pins of the *same* cert hash minted at
        // different times are distinct policy values (a rotation must be
        // explicit), even though the pinned hash matches the same leaf.
        let pinned = LeafCertificateTrust.sha256(ofLeafCertificateDER: leafA)
        let policyOne = TrustPolicy.pinnedLeaf(sha256: pinned, revision: UUID())
        let policyTwo = TrustPolicy.pinnedLeaf(sha256: pinned, revision: UUID())
        XCTAssertNotEqual(policyOne, policyTwo)
        // But both still accept the same leaf DER on their own terms.
        XCTAssertNil(LeafCertificateTrust.evaluatePinnedLeaf(leafA, against: policyOne))
        XCTAssertNil(LeafCertificateTrust.evaluatePinnedLeaf(leafA, against: policyTwo))
    }

    func testSystemPolicyIsNotHandledByPinnedLeafEvaluator() {
        // `.system` trust is handled entirely by `SystemTrustEvaluator`
        // (platform chain+hostname validation) — the pure pinned-leaf
        // matcher must be a no-op (never reject) for `.system`, since it
        // isn't responsible for that policy at all.
        XCTAssertNil(LeafCertificateTrust.evaluatePinnedLeaf(leafA, against: .system))
    }
}
