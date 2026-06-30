import XCTest
@testable import CoreModels

/// Tests for the pure per-content-type subtitle policy and its per-profile store.
final class SubtitlePolicyTests: XCTestCase {

    // MARK: - effectiveRule precedence

    func testEffectiveRuleFallsBackToBaseWhenNoOverride() {
        let base = SubtitlePolicy.Rule(mode: .all, preferredLanguages: ["en"])
        let policy = SubtitlePolicy(basePolicy: base)
        XCTAssertEqual(policy.effectiveRule(for: .movie), base)
        XCTAssertEqual(policy.effectiveRule(for: .anime), base)
        XCTAssertEqual(policy.effectiveRule(for: .other), base)
    }

    func testEffectiveRulePrefersOverride() {
        let base = SubtitlePolicy.Rule(mode: .all, preferredLanguages: ["en"])
        let forcedMovies = SubtitlePolicy.Rule(mode: .forcedOnly, preferredLanguages: ["en"])
        let policy = SubtitlePolicy(basePolicy: base, overrides: [.movie: forcedMovies])
        XCTAssertEqual(policy.effectiveRule(for: .movie), forcedMovies)
        XCTAssertEqual(policy.effectiveRule(for: .anime), base, "categories without an override still inherit the base")
    }

    // MARK: - inheriting(from:) is behaviour-preserving

    func testInheritingMirrorsCaptionSettings() {
        let caption = CaptionSettings(autoDownloadSubtitles: true, subtitleMode: .forcedOnly, preferredSubtitleLanguage: "fr")
        let policy = SubtitlePolicy.inheriting(from: caption)
        let rule = policy.effectiveRule(for: .movie)
        XCTAssertEqual(rule.mode, .forcedOnly)
        XCTAssertEqual(rule.preferredLanguages, ["fr"])
        XCTAssertTrue(rule.autoDownloadIfMissing)
        XCTAssertTrue(policy.overrides.isEmpty, "inheriting carries no per-type overrides")
    }

    func testInheritingUsesResolvedLanguageWhenUnset() {
        // No explicit language → resolvedPreferredLanguage falls back to device.
        let caption = CaptionSettings(preferredSubtitleLanguage: nil)
        let policy = SubtitlePolicy.inheriting(from: caption)
        XCTAssertEqual(policy.basePolicy.preferredLanguages, caption.resolvedPreferredLanguage.map { [$0] } ?? [])
    }

    // MARK: - smartDefaultOverrides seed (the user's example matrix)

    func testSmartDefaultsSeedMatrix() {
        let base = SubtitlePolicy.Rule(mode: .all, preferredLanguages: ["en"])
        let seed = SubtitlePolicy.smartDefaultOverrides(base: base)
        XCTAssertEqual(seed[.movie]?.mode, .forcedOnly, "movies default to forced-only")
        XCTAssertEqual(seed[.anime]?.mode, .all)
        XCTAssertEqual(seed[.anime]?.autoDownloadIfMissing, true, "anime auto-downloads a missing match")
        XCTAssertEqual(seed[.tvShow]?.mode, .all)
        XCTAssertNil(seed[.other], "no seed for the catch-all category")
    }

    func testSmartDefaultsFallBackToEnglishWhenBaseHasNoLanguage() {
        let seed = SubtitlePolicy.smartDefaultOverrides(base: SubtitlePolicy.Rule(preferredLanguages: []))
        XCTAssertEqual(seed[.anime]?.preferredLanguages, ["en"])
    }

    func testSmartDefaultsHonourBaseLanguage() {
        let seed = SubtitlePolicy.smartDefaultOverrides(base: SubtitlePolicy.Rule(preferredLanguages: ["de"]))
        XCTAssertEqual(seed[.movie]?.preferredLanguages, ["de"])
    }

    // MARK: - Rule.decision feeds SubtitleSelector

    func testForcedOnlyRulePicksForcedTrack() {
        let candidates = [
            SubtitleCandidate(id: 1, languageCode: "en", isForced: false),
            SubtitleCandidate(id: 2, languageCode: "en", isForced: true)
        ]
        let rule = SubtitlePolicy.Rule(mode: .forcedOnly, preferredLanguages: ["en"])
        XCTAssertEqual(rule.decision(candidates: candidates), .select(id: 2))
    }

    func testAllRulePicksFullTrack() {
        let candidates = [
            SubtitleCandidate(id: 1, languageCode: "en", isForced: false),
            SubtitleCandidate(id: 2, languageCode: "en", isForced: true)
        ]
        let rule = SubtitlePolicy.Rule(mode: .all, preferredLanguages: ["en"])
        XCTAssertEqual(rule.decision(candidates: candidates), .select(id: 1))
    }

    func testRuleDecisionUsesFirstPreferredLanguage() {
        let candidates = [SubtitleCandidate(id: 7, languageCode: "ja", isForced: false)]
        let rule = SubtitlePolicy.Rule(mode: .all, preferredLanguages: ["ja", "en"])
        XCTAssertEqual(rule.preferredLanguage, "ja")
        XCTAssertEqual(rule.decision(candidates: candidates), .select(id: 7))
    }

    // MARK: - Codable round-trip

    func testPolicyCodableRoundTripWithOverrides() throws {
        let policy = SubtitlePolicy(
            basePolicy: SubtitlePolicy.Rule(mode: .all, preferredLanguages: ["en"], autoDownloadIfMissing: false),
            overrides: SubtitlePolicy.smartDefaultOverrides(base: SubtitlePolicy.Rule(preferredLanguages: ["en"]))
        )
        let data = try JSONEncoder().encode(policy)
        let decoded = try JSONDecoder().decode(SubtitlePolicy.self, from: data)
        XCTAssertEqual(decoded, policy)
        XCTAssertEqual(decoded.effectiveRule(for: .movie).mode, .forcedOnly)
    }

    func testCategoryRawValuesAreStable() {
        // Persisted raw values must not change or stored overrides would be lost.
        XCTAssertEqual(SubtitleContentCategory.anime.rawValue, "anime")
        XCTAssertEqual(SubtitleContentCategory.movie.rawValue, "movie")
        XCTAssertEqual(SubtitleContentCategory.tvShow.rawValue, "tvShow")
        XCTAssertEqual(SubtitleContentCategory.other.rawValue, "other")
    }

    // MARK: - Store

    private func makeDefaults() -> UserDefaults {
        let suite = "SubtitlePolicyStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testStoreStartsEmptyAndInherits() {
        let store = SubtitlePolicyStore(defaults: makeDefaults())
        XCTAssertTrue(store.overrides().isEmpty)
        let caption = CaptionSettings(subtitleMode: .all, preferredSubtitleLanguage: "en")
        let resolved = store.resolvedPolicy(caption: caption)
        // With no overrides, every category resolves to the caption-derived base.
        XCTAssertEqual(resolved.effectiveRule(for: .movie).mode, .all)
        XCTAssertEqual(resolved.effectiveRule(for: .movie).preferredLanguages, ["en"])
        XCTAssertTrue(resolved.overrides.isEmpty)
    }

    func testStoreSetAndClearRule() {
        let store = SubtitlePolicyStore(defaults: makeDefaults())
        let forced = SubtitlePolicy.Rule(mode: .forcedOnly, preferredLanguages: ["en"])
        store.setRule(forced, for: .movie)
        XCTAssertEqual(store.overrides()[.movie], forced)

        store.setRule(nil, for: .movie)
        XCTAssertNil(store.overrides()[.movie], "setting nil clears the override")
        XCTAssertTrue(store.overrides().isEmpty)
    }

    func testStoreResolvedPolicyCombinesBaseAndOverrides() {
        let store = SubtitlePolicyStore(defaults: makeDefaults())
        store.setRule(SubtitlePolicy.Rule(mode: .forcedOnly, preferredLanguages: ["en"]), for: .movie)
        let caption = CaptionSettings(subtitleMode: .all, preferredSubtitleLanguage: "en")
        let resolved = store.resolvedPolicy(caption: caption)
        XCTAssertEqual(resolved.effectiveRule(for: .movie).mode, .forcedOnly, "override wins for movies")
        XCTAssertEqual(resolved.effectiveRule(for: .anime).mode, .all, "anime inherits the caption base")
    }

    func testStorePersistsAcrossInstances() {
        let defaults = makeDefaults()
        SubtitlePolicyStore(defaults: defaults)
            .setRule(SubtitlePolicy.Rule(mode: .forcedOnly), for: .movie)
        let reopened = SubtitlePolicyStore(defaults: defaults)
        XCTAssertEqual(reopened.overrides()[.movie]?.mode, .forcedOnly)
    }

    func testStoreNamespaceIsolatesProfiles() {
        let defaults = makeDefaults()
        let primary = SubtitlePolicyStore(defaults: defaults, namespace: nil)
        let other = SubtitlePolicyStore(defaults: defaults, namespace: "profile-b")
        primary.setRule(SubtitlePolicy.Rule(mode: .forcedOnly), for: .movie)
        XCTAssertEqual(primary.overrides()[.movie]?.mode, .forcedOnly)
        XCTAssertTrue(other.overrides().isEmpty, "a second profile has independent policy")
    }

    func testStoreSetOverridesReplacesWhole() {
        let store = SubtitlePolicyStore(defaults: makeDefaults())
        store.setRule(SubtitlePolicy.Rule(mode: .forcedOnly), for: .anime)
        let seed = SubtitlePolicy.smartDefaultOverrides(base: SubtitlePolicy.Rule(preferredLanguages: ["en"]))
        store.setOverrides(seed)
        XCTAssertEqual(store.overrides()[.anime]?.mode, .all, "adopting the seed replaces prior overrides")
        XCTAssertEqual(store.overrides()[.movie]?.mode, .forcedOnly)

        store.setOverrides([:])
        XCTAssertTrue(store.overrides().isEmpty, "clearing to empty removes the persisted entry")
    }
}
