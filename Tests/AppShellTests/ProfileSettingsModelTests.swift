import XCTest
import CoreModels
@testable import AppShell

/// Unit tests for ``ProfileSettingsModel`` — the per-profile settings facet split
/// out of ``AppState``. Verifies the two behaviours that used to live in
/// `AppState.rebuildSettingsModels()`: namespace-scoped (re)builds swap the
/// sub-models on profile switch, and injected models (the test path) are treated
/// as immutable and never rebuilt.
@MainActor
final class ProfileSettingsModelTests: XCTestCase {

    func testDefaultBuildIsNotTreatedAsInjected() {
        let model = ProfileSettingsModel(namespace: "ns-a")
        XCTAssertFalse(model.usesInjectedModels)
    }

    func testRebuildSwapsSubModelInstances() {
        let model = ProfileSettingsModel(namespace: "ns-a")
        let themeBefore = ObjectIdentifier(model.themeModel)
        let subtitleBefore = ObjectIdentifier(model.subtitleBehaviorModel)
        // A non-injectable model (always built) must also swap.
        let heroBefore = ObjectIdentifier(model.heroSettingsModel)

        model.rebuild(namespace: "ns-b")

        XCTAssertNotEqual(themeBefore, ObjectIdentifier(model.themeModel))
        XCTAssertNotEqual(subtitleBefore, ObjectIdentifier(model.subtitleBehaviorModel))
        XCTAssertNotEqual(heroBefore, ObjectIdentifier(model.heroSettingsModel))
    }

    /// `rebuild(namespace:)` must swap *every* one of the 18 sub-models, not just a
    /// representative few — a missed model would silently freeze to the old profile.
    func testRebuildSwapsAllEighteenSubModelInstances() {
        let model = ProfileSettingsModel(namespace: "ns-a")

        let before: [ObjectIdentifier] = [
            ObjectIdentifier(model.subtitleBehaviorModel),
            ObjectIdentifier(model.subtitleStyleModel),
            ObjectIdentifier(model.spoilerModel),
            ObjectIdentifier(model.playbackModel),
            ObjectIdentifier(model.subtitlePolicyModel),
            ObjectIdentifier(model.audioPolicyModel),
            ObjectIdentifier(model.themeModel),
            ObjectIdentifier(model.themeMusicModel),
            ObjectIdentifier(model.diagnosticsModel),
            ObjectIdentifier(model.musicPlayerModel),
            ObjectIdentifier(model.homeLibraryVisibilityModel),
            ObjectIdentifier(model.uiDensityModel),
            ObjectIdentifier(model.cardStyleModel),
            ObjectIdentifier(model.watchStatusIndicatorModel),
            ObjectIdentifier(model.navigationStyleModel),
            ObjectIdentifier(model.transparencyModel),
            ObjectIdentifier(model.heroSettingsModel),
            ObjectIdentifier(model.nightShiftModel),
        ]
        XCTAssertEqual(before.count, 18, "Expected 18 per-profile sub-models")

        model.rebuild(namespace: "ns-b")

        let after: [ObjectIdentifier] = [
            ObjectIdentifier(model.subtitleBehaviorModel),
            ObjectIdentifier(model.subtitleStyleModel),
            ObjectIdentifier(model.spoilerModel),
            ObjectIdentifier(model.playbackModel),
            ObjectIdentifier(model.subtitlePolicyModel),
            ObjectIdentifier(model.audioPolicyModel),
            ObjectIdentifier(model.themeModel),
            ObjectIdentifier(model.themeMusicModel),
            ObjectIdentifier(model.diagnosticsModel),
            ObjectIdentifier(model.musicPlayerModel),
            ObjectIdentifier(model.homeLibraryVisibilityModel),
            ObjectIdentifier(model.uiDensityModel),
            ObjectIdentifier(model.cardStyleModel),
            ObjectIdentifier(model.watchStatusIndicatorModel),
            ObjectIdentifier(model.navigationStyleModel),
            ObjectIdentifier(model.transparencyModel),
            ObjectIdentifier(model.heroSettingsModel),
            ObjectIdentifier(model.nightShiftModel),
        ]

        for (index, (old, new)) in zip(before, after).enumerated() {
            XCTAssertNotEqual(old, new, "Sub-model at index \(index) was not swapped on rebuild")
        }
    }

    /// A namespace round-trip: rebuilding to a new namespace and back builds fresh
    /// instances each time (state is scoped to the namespace, never reused), and a
    /// same-namespace round-trip still swaps because rebuild always constructs anew.
    func testRebuildRoundTripScopesToNamespace() {
        let model = ProfileSettingsModel(namespace: "ns-a")
        let themeA = ObjectIdentifier(model.themeModel)

        model.rebuild(namespace: "ns-b")
        let themeB = ObjectIdentifier(model.themeModel)
        XCTAssertNotEqual(themeA, themeB)

        // Returning to the original namespace rebuilds fresh state scoped to it
        // rather than restoring the prior instance.
        model.rebuild(namespace: "ns-a")
        let themeABack = ObjectIdentifier(model.themeModel)
        XCTAssertNotEqual(themeB, themeABack)
        XCTAssertNotEqual(themeA, themeABack)
    }

    /// The three models that previously had no injection parameter
    /// (`subtitlePolicyModel`, `audioPolicyModel`, `heroSettingsModel`) are now
    /// injectable and preserved as-is, mirroring the other injected models.
    func testNewlyInjectableModelsArePreservedAndNotRebuilt() {
        let injectedSubtitlePolicy = SubtitlePolicyModel(store: SubtitlePolicyStore(namespace: "seed"))
        let injectedAudioPolicy = AudioPolicyModel(store: AudioPolicyStore(namespace: "seed"))
        let injectedHero = HeroSettingsModel(store: HeroSettingsStore(namespace: "seed"))

        let model = ProfileSettingsModel(
            namespace: "ns-a",
            subtitlePolicyModel: injectedSubtitlePolicy,
            audioPolicyModel: injectedAudioPolicy,
            heroSettingsModel: injectedHero
        )

        XCTAssertTrue(model.usesInjectedModels)
        XCTAssertTrue(model.subtitlePolicyModel === injectedSubtitlePolicy)
        XCTAssertTrue(model.audioPolicyModel === injectedAudioPolicy)
        XCTAssertTrue(model.heroSettingsModel === injectedHero)

        // Rebuild is a no-op under injection: identities are preserved.
        model.rebuild(namespace: "ns-b")
        XCTAssertTrue(model.subtitlePolicyModel === injectedSubtitlePolicy)
        XCTAssertTrue(model.audioPolicyModel === injectedAudioPolicy)
        XCTAssertTrue(model.heroSettingsModel === injectedHero)
    }

    func testInjectedModelsAreNotRebuilt() {
        let injectedTheme = ThemeSettingsModel(store: ThemeSettingsStore(namespace: "seed"))
        let model = ProfileSettingsModel(namespace: "ns-a", themeModel: injectedTheme)
        XCTAssertTrue(model.usesInjectedModels)
        XCTAssertTrue(model.themeModel === injectedTheme)

        let subtitleBefore = ObjectIdentifier(model.subtitleBehaviorModel)
        model.rebuild(namespace: "ns-b")

        // Rebuild is a no-op when models were injected: identity is preserved.
        XCTAssertTrue(model.themeModel === injectedTheme)
        XCTAssertEqual(subtitleBefore, ObjectIdentifier(model.subtitleBehaviorModel))
    }
}
