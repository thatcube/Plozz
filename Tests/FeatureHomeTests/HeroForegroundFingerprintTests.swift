import XCTest
@testable import FeatureHome

/// Locks down the hero foreground fingerprint's equality contract: any field that
/// changes what the description column draws must flip equality (so the raster
/// regenerates), while an identical snapshot stays equal (so it is reused).
final class HeroForegroundFingerprintTests: XCTestCase {
    private func make(
        itemID: String = "item-1",
        title: String = "The Show",
        overview: String? = "An overview.",
        metadata: String = "2024 · 1h 42m · Drama",
        ratingBadgeID: String? = "TV-MA",
        logoURLString: String? = "https://example/logo.png",
        isDarkMode: Bool = true,
        contentWidth: Int = 620
    ) -> HeroForegroundFingerprint {
        HeroForegroundFingerprint(
            itemID: itemID, title: title, overview: overview, metadata: metadata,
            ratingBadgeID: ratingBadgeID, logoURLString: logoURLString,
            isDarkMode: isDarkMode, contentWidth: contentWidth
        )
    }

    func testIdenticalSnapshotsAreEqual() {
        XCTAssertEqual(make(), make())
        XCTAssertEqual(make().hashValue, make().hashValue)
    }

    func testEachFieldChangeBreaksEquality() {
        XCTAssertNotEqual(make(), make(itemID: "item-2"))
        XCTAssertNotEqual(make(), make(title: "Different"))
        XCTAssertNotEqual(make(), make(overview: "Other"))
        XCTAssertNotEqual(make(), make(overview: nil))
        XCTAssertNotEqual(make(), make(metadata: "2023"))
        XCTAssertNotEqual(make(), make(ratingBadgeID: nil))
        XCTAssertNotEqual(make(), make(logoURLString: "https://example/other.png"))
        XCTAssertNotEqual(make(), make(logoURLString: nil))
        XCTAssertNotEqual(make(), make(isDarkMode: false))
        XCTAssertNotEqual(make(), make(contentWidth: 700))
    }

    func testThemeFlipRegenerates() {
        // Text/shadow tints are appearance-dependent, so a scheme change must
        // regenerate the snapshot rather than reuse a light snapshot in dark mode.
        XCTAssertNotEqual(make(), make(isDarkMode: false))
    }

    func testSpoilerToggleRegenerates() {
        // Spoiler masking changes the drawn title and drops the overview.
        XCTAssertNotEqual(make(), make(title: "•••••••", overview: nil))
    }
}
