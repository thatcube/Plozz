import XCTest
@testable import CoreModels

final class ProfileModelTests: XCTestCase {
    func testDefaultProfileUsesNilNamespaceOnlyWhenDefault() {
        let p = Profile(id: "abc", name: "Mom")
        XCTAssertNil(p.settingsNamespace(isDefault: true))
        XCTAssertEqual(p.settingsNamespace(isDefault: false), "abc")
    }

    func testColorIndexIsClampedAndWraps() {
        XCTAssertEqual(Profile(name: "A", colorIndex: 0).clampedColorIndex, 0)
        XCTAssertEqual(Profile(name: "A", colorIndex: Profile.tileColorCount).clampedColorIndex, 0)
        XCTAssertEqual(Profile(name: "A", colorIndex: -1).clampedColorIndex,
                       Profile.tileColorCount - 1)
    }

    func testCodableRoundTrip() throws {
        let p = Profile(
            id: "p1",
            name: "Dad",
            avatarSymbol: "film.fill",
            colorIndex: 3,
            createdAt: Date(timeIntervalSince1970: 100),
            linkedAccountID: "acct-9"
        )
        let data = try JSONEncoder().encode(p)
        XCTAssertEqual(try JSONDecoder().decode(Profile.self, from: data), p)
    }

    func testSettingSeerrUserSetsAndClears() {
        let base = Profile(id: "p1", name: "Dad")
        XCTAssertNil(base.seerrUserID)

        let mapped = base.settingSeerrUser(id: 7, name: "Dad (Seerr)", avatarURL: "https://x/y.png")
        XCTAssertEqual(mapped.seerrUserID, 7)
        XCTAssertEqual(mapped.seerrUserName, "Dad (Seerr)")
        XCTAssertEqual(mapped.seerrUserAvatarURL, "https://x/y.png")

        let cleared = mapped.settingSeerrUser(id: nil)
        XCTAssertNil(cleared.seerrUserID)
        XCTAssertNil(cleared.seerrUserName, "Clearing the id drops the cached name")
        XCTAssertNil(cleared.seerrUserAvatarURL)
    }

    func testSeerrUserMappingSurvivesCodableRoundTrip() throws {
        let p = Profile(id: "p2", name: "Mom").settingSeerrUser(id: 42, name: "Mom", avatarURL: nil)
        let data = try JSONEncoder().encode(p)
        let decoded = try JSONDecoder().decode(Profile.self, from: data)
        XCTAssertEqual(decoded.seerrUserID, 42)
        XCTAssertEqual(decoded, p)
    }

    func testLegacyProfileJSONWithoutSeerrFieldsDecodesToNil() throws {
        // A profile encoded before seerrUserID existed must decode cleanly.
        let legacyJSON = #"{"id":"p3","name":"Kid","avatarSymbol":"star.circle.fill","colorIndex":0,"createdAt":0}"#
        let decoded = try JSONDecoder().decode(Profile.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(decoded.id, "p3")
        XCTAssertNil(decoded.seerrUserID)
        XCTAssertNil(decoded.seerrUserName)
    }

    // MARK: Avatar symbols

    func testDefaultAvatarSymbolIsStablePerson() {
        // Several call sites use `defaultAvatarSymbols[0]` as the app-wide
        // default avatar — keep it the person crop circle.
        XCTAssertEqual(Profile.defaultAvatarSymbols.first, "person.crop.circle.fill")
    }

    func testDefaultAvatarSymbolsAreTheFlattenedCategories() {
        XCTAssertEqual(
            Profile.defaultAvatarSymbols,
            Profile.avatarSymbolCategories.flatMap(\.symbols)
        )
    }

    func testAvatarSymbolsHaveNoDuplicates() {
        let all = Profile.defaultAvatarSymbols
        XCTAssertEqual(all.count, Set(all).count, "Avatar symbols should be unique")
    }

    func testAvatarSymbolCategoriesAreNonEmpty() {
        XCTAssertFalse(Profile.avatarSymbolCategories.isEmpty)
        for category in Profile.avatarSymbolCategories {
            XCTAssertFalse(category.title.isEmpty)
            XCTAssertFalse(category.symbols.isEmpty, "\(category.title) has no symbols")
        }
    }

    func testEveryAvatarCategoryHasEightSymbols() {
        // The editor lays each category out as one row of 8; a category with a
        // different count would orphan or wrap icons.
        for category in Profile.avatarSymbolCategories {
            XCTAssertEqual(category.symbols.count, 8, "\(category.title) must hold exactly 8 symbols")
        }
    }

    // MARK: Emoji avatars

    func testEmojiCategoriesAreEightWideAndNonEmpty() {
        XCTAssertFalse(Profile.avatarEmojiCategories.isEmpty)
        for category in Profile.avatarEmojiCategories {
            XCTAssertFalse(category.title.isEmpty)
            XCTAssertFalse(category.emojis.isEmpty, "\(category.title) has no emoji")
            // Laid out 8 per row; a multiple of 8 keeps rows clean.
            XCTAssertEqual(category.emojis.count % 8, 0, "\(category.title) should be a multiple of 8")
        }
    }

    func testAvatarEmojiAvailabilityGate() {
        let safe = AvatarEmoji("😎")
        let new = AvatarEmoji("🫩", minMajor: 18, minMinor: 4)
        // Ungated is always available.
        XCTAssertTrue(safe.isAvailable(osMajor: 18, osMinor: 0))
        // Gated hides below its floor, shows at/above it.
        XCTAssertFalse(new.isAvailable(osMajor: 18, osMinor: 0))
        XCTAssertFalse(new.isAvailable(osMajor: 18, osMinor: 3))
        XCTAssertTrue(new.isAvailable(osMajor: 18, osMinor: 4))
        XCTAssertTrue(new.isAvailable(osMajor: 19, osMinor: 0))
    }

    func testAvailableEmojisFilterByOS() {
        let cat = AvatarEmojiCategory(title: "T", emojis: [
            AvatarEmoji("😎"), AvatarEmoji("🫩", minMajor: 18, minMinor: 4)
        ])
        XCTAssertEqual(cat.availableEmojis(osMajor: 18, osMinor: 0).map(\.value), ["😎"])
        XCTAssertEqual(cat.availableEmojis(osMajor: 18, osMinor: 4).map(\.value), ["😎", "🫩"])
    }

    func testRandomAvatarEmojiIsFromUngatedPool() {
        let ungated = Set(
            Profile.avatarEmojiCategories.flatMap(\.emojis).filter { $0.minMajor == 0 }.map(\.value)
        )
        XCTAssertFalse(ungated.isEmpty)
        for _ in 0..<50 {
            XCTAssertTrue(ungated.contains(Profile.randomAvatarEmoji()))
        }
    }

    func testAvatarEmojiRoundTripsAndDefaultsNil() throws {
        XCTAssertNil(Profile(name: "A").avatarEmoji)
        XCTAssertNil(Profile(name: "A").avatarEmojiColorIndex)
        let p = Profile(name: "Kid", avatarEmoji: "🦖", avatarEmojiColorIndex: 3)
        let decoded = try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(decoded.avatarEmoji, "🦖")
        XCTAssertEqual(decoded.avatarEmojiColorIndex, 3)
        XCTAssertEqual(decoded, p)
    }

    func testLegacyProfileJSONWithoutAvatarEmojiDecodesToNil() throws {
        // A profile encoded before avatarEmoji existed must decode cleanly.
        let legacyJSON = #"{"id":"p9","name":"Dad","avatarSymbol":"person.fill","colorIndex":1,"createdAt":0}"#
        let decoded = try JSONDecoder().decode(Profile.self, from: Data(legacyJSON.utf8))
        XCTAssertNil(decoded.avatarEmoji)
        XCTAssertNil(decoded.avatarEmojiColorIndex)
    }

    // MARK: Suggested colour for new profiles

    func testSuggestedColorIndexPicksFirstUnused() {
        XCTAssertEqual(Profile.suggestedColorIndex(existingColorIndices: []), 0)
        XCTAssertEqual(Profile.suggestedColorIndex(existingColorIndices: [0]), 1)
        XCTAssertEqual(Profile.suggestedColorIndex(existingColorIndices: [0, 1, 2]), 3)
        // Order/gaps don't matter — it fills the lowest free slot.
        XCTAssertEqual(Profile.suggestedColorIndex(existingColorIndices: [2, 0]), 1)
    }

    func testSuggestedColorIndexNormalizesOutOfRange() {
        // An out-of-range existing index still marks its wrapped slot as used.
        XCTAssertEqual(
            Profile.suggestedColorIndex(existingColorIndices: [Profile.tileColorCount]), // wraps to 0
            1
        )
    }

    func testSuggestedColorIndexRotatesWhenAllUsed() {
        let all = Array(0..<Profile.tileColorCount)
        // Every colour taken → rotate by how many profiles exist.
        XCTAssertEqual(
            Profile.suggestedColorIndex(existingColorIndices: all),
            all.count % Profile.tileColorCount
        )
    }
}
