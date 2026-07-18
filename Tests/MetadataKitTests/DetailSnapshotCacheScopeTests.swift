import XCTest
@testable import MetadataKit

/// Locks the E1 invariant that detail snapshots are scoped to the full effective
/// content identity: a change to the profile or to any account/credential material
/// yields a different, filesystem-safe, secret-free scope digest, while unchanged
/// identity material yields a stable, reusable scope.
final class DetailSnapshotCacheScopeTests: XCTestCase {
    func testDifferentProfilesProduceDifferentDigests() {
        let a = DetailSnapshotCacheScope(profileID: "alice", identityMaterial: "acct-1")
        let b = DetailSnapshotCacheScope(profileID: "bob", identityMaterial: "acct-1")
        XCTAssertNotEqual(a.digest, b.digest)
        XCTAssertNotEqual(a, b)
    }

    func testDifferentIdentityMaterialProducesDifferentDigests() {
        // A single string channels every content-identity change the app folds in
        // (provider enable/disable, credential rotation, account removal/re-add,
        // Plex Home-user generation). Any change to it must change the scope.
        let base = DetailSnapshotCacheScope(profileID: "p", identityMaterial: "a#r1")
        let rotated = DetailSnapshotCacheScope(profileID: "p", identityMaterial: "a#r2")
        let added = DetailSnapshotCacheScope(profileID: "p", identityMaterial: "a#r1|b#r1")
        XCTAssertNotEqual(base.digest, rotated.digest)
        XCTAssertNotEqual(base.digest, added.digest)
        XCTAssertNotEqual(rotated.digest, added.digest)
    }

    func testEqualInputsProduceEqualDeterministicScope() {
        let first = DetailSnapshotCacheScope(profileID: "p", identityMaterial: "a#r1|b#r2")
        let second = DetailSnapshotCacheScope(profileID: "p", identityMaterial: "a#r1|b#r2")
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.digest, second.digest)
        XCTAssertEqual(first.directoryComponent, second.directoryComponent)
    }

    func testDigestIsFixedLengthLowercaseHex() {
        let scope = DetailSnapshotCacheScope(
            profileID: "profile-with-emoji-🎬",
            identityMaterial: "server/path secret token PIN username"
        )
        XCTAssertEqual(scope.digest.count, 64)
        XCTAssertTrue(scope.digest.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        XCTAssertEqual(scope.directoryComponent, scope.digest)
    }

    func testDigestDoesNotEmbedSecretOrIdentityMaterial() {
        let secretMaterial = "token=SUPER_SECRET_123 user=brandon share=//nas/movies"
        let scope = DetailSnapshotCacheScope(profileID: "brandon", identityMaterial: secretMaterial)
        XCTAssertFalse(scope.digest.contains("SUPER_SECRET_123"))
        XCTAssertFalse(scope.digest.contains("brandon"))
        XCTAssertFalse(scope.digest.contains("nas"))
        XCTAssertFalse(scope.digest.contains("token"))
    }

    func testProfileAndMaterialAreNotIndependentlySwappable() {
        // Folding the profile into the digest (not just concatenating) means moving
        // a boundary between the two fields cannot collide two distinct identities.
        let a = DetailSnapshotCacheScope(profileID: "ab", identityMaterial: "cd")
        let b = DetailSnapshotCacheScope(profileID: "a", identityMaterial: "bcd")
        XCTAssertNotEqual(a.digest, b.digest)
    }
}
