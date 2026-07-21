import XCTest
@testable import FeatureSyncSetup

final class SyncPairingSASTests: XCTestCase {
    private let hostKey = SyncPairingIdentity().publicKeyData

    func testCodeIsDeterministicAndSixDigits() {
        let hn = SyncPairingSAS.makeNonce(), gn = SyncPairingSAS.makeNonce()
        let a = SyncPairingSAS.code(hostPublicKey: hostKey, hostNonce: hn, guestNonce: gn, ceremonyID: "c")
        let b = SyncPairingSAS.code(hostPublicKey: hostKey, hostNonce: hn, guestNonce: gn, ceremonyID: "c")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 6)
        XCTAssertTrue(a.allSatisfy(\.isNumber))
    }

    func testSubstitutedKeyYieldsDifferentCode() {
        // The receiver's SAS is computed from its REAL key; a MITM makes the guest
        // compute from the ATTACKER's key. The two codes must differ so the human
        // catches it. (Astronomically unlikely 1e-6 accidental collision aside.)
        let hn = SyncPairingSAS.makeNonce(), gn = SyncPairingSAS.makeNonce()
        let real = SyncPairingSAS.code(hostPublicKey: hostKey, hostNonce: hn, guestNonce: gn, ceremonyID: "c")
        let attackerKey = SyncPairingIdentity().publicKeyData
        let seen = SyncPairingSAS.code(hostPublicKey: attackerKey, hostNonce: hn, guestNonce: gn, ceremonyID: "c")
        XCTAssertNotEqual(real, seen)
    }

    func testDifferentNoncesOrCeremonyChangeCode() {
        let base = SyncPairingSAS.code(hostPublicKey: hostKey, hostNonce: Data([1]), guestNonce: Data([2]), ceremonyID: "c")
        XCTAssertNotEqual(base, SyncPairingSAS.code(hostPublicKey: hostKey, hostNonce: Data([9]), guestNonce: Data([2]), ceremonyID: "c"))
        XCTAssertNotEqual(base, SyncPairingSAS.code(hostPublicKey: hostKey, hostNonce: Data([1]), guestNonce: Data([9]), ceremonyID: "c"))
        XCTAssertNotEqual(base, SyncPairingSAS.code(hostPublicKey: hostKey, hostNonce: Data([1]), guestNonce: Data([2]), ceremonyID: "d"))
    }

    func testCommitmentVerifies() {
        let ng = SyncPairingSAS.makeNonce()
        let commit = SyncPairingSAS.commitment(forGuestNonce: ng)
        XCTAssertTrue(SyncPairingSAS.verify(commitment: commit, matchesGuestNonce: ng))
        XCTAssertFalse(SyncPairingSAS.verify(commitment: commit, matchesGuestNonce: SyncPairingSAS.makeNonce()))
    }

    func testGroupedFormatting() {
        XCTAssertEqual(SyncPairingSAS.grouped("482193"), "482 193")
    }
}
