import XCTest
@testable import ProviderShare

/// Guards the two rules that decide whether a directory is re-listed.
///
/// Both are correctness-critical in the same direction: getting them wrong means
/// a folder is skipped forever and newly-added media never appears. The tests
/// therefore lean on the conservative side — a rule may cost an extra listing,
/// but must never make something invisible.
final class ShareScannerIncrementalTests: XCTestCase {

    // MARK: Which directories have children

    /// A directory is only skippable when it has no subdirectories, because one
    /// listing is what yields its children's mtimes — skipping the parent
    /// forfeits that and forces every child to be listed instead.
    func testParentPathsIdentifiesDirectoriesWithChildren() {
        let recorded = [
            "Movies",
            "Movies/Arrival (2016)",
            "TV",
            "TV/Fargo",
            "TV/Fargo/Season 01"
        ]
        let parents = ShareScanner.parentPaths(of: recorded)

        // Interior nodes: must be listed even when unchanged.
        XCTAssertTrue(parents.contains("Movies"))
        XCTAssertTrue(parents.contains("TV"))
        XCTAssertTrue(parents.contains("TV/Fargo"))
        // Leaves: skippable when their mtime is unchanged.
        XCTAssertFalse(parents.contains("Movies/Arrival (2016)"))
        XCTAssertFalse(parents.contains("TV/Fargo/Season 01"))
    }

    /// Top-level directories make the share root a parent, so the root is never
    /// mistaken for a leaf and skipped — which would hide the entire library.
    func testTopLevelDirectoriesMakeTheRootAParent() {
        XCTAssertTrue(ShareScanner.parentPaths(of: ["Movies"]).contains(""))
    }

    func testParentPathsIgnoresTheRootItself() {
        XCTAssertTrue(ShareScanner.parentPaths(of: [""]).isEmpty)
        XCTAssertTrue(ShareScanner.parentPaths(of: []).isEmpty)
    }

    // MARK: Racy timestamps

    /// A settled mtime is trusted, so an unchanged folder can be skipped.
    func testTrustsAnMTimeComfortablyInThePast() {
        let now = Date()
        let settled = now.addingTimeInterval(-3600)
        XCTAssertEqual(ShareScanner.trustworthyMTime(settled, now: now), settled)
    }

    /// The racy-timestamp case: a file landing in the same second the scan reads
    /// the directory leaves an mtime equal to the one recorded, so the folder
    /// would look unchanged forever. Refusing to record it costs one listing next
    /// pass and self-corrects.
    func testRejectsAnMTimeTooCloseToNow() {
        let now = Date()
        XCTAssertNil(ShareScanner.trustworthyMTime(now, now: now))
        XCTAssertNil(ShareScanner.trustworthyMTime(now.addingTimeInterval(-0.5), now: now))
    }

    /// One-second filesystem granularity means the whole tick has to be excluded,
    /// not just the instant.
    func testRejectsAnMTimeInsideTheGranularityWindow() {
        let now = Date()
        let justInside = now.addingTimeInterval(-(ShareScanner.racyMTimeWindow - 0.1))
        XCTAssertNil(ShareScanner.trustworthyMTime(justInside, now: now))

        let justOutside = now.addingTimeInterval(-(ShareScanner.racyMTimeWindow + 0.1))
        XCTAssertEqual(ShareScanner.trustworthyMTime(justOutside, now: now), justOutside)
    }

    /// A server clock running ahead yields a future mtime. Treated as untrusted
    /// rather than clamped: the comparison it would feed is equality, and a
    /// future stamp says the folder may still be being written.
    func testRejectsAFutureMTime() {
        let now = Date()
        XCTAssertNil(ShareScanner.trustworthyMTime(now.addingTimeInterval(60), now: now))
    }

    /// A transport that reports no directory mtime (some SMB/NFS servers) records
    /// nothing, so the folder is always listed.
    func testRejectsAMissingMTime() {
        XCTAssertNil(ShareScanner.trustworthyMTime(nil))
    }
}
