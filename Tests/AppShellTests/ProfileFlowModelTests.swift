import XCTest
import CoreModels
import FeatureAuth
import FeatureMusic
@testable import AppShell

/// Unit tests for ``ProfileFlowModel`` — the profile-flow + household facet split
/// out of ``AppState``. Cover the picker-state machine (request / cancel / launch
/// picker / new-profile theme) deterministically. The full switch/save/remove and
/// household-membership orchestration stays covered end-to-end by ServerToggleTests,
/// which now exercises it through `state.profileFlow.*`.
@MainActor
final class ProfileFlowModelTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let suite = "ProfileFlowModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeModel() -> (ProfileFlowModel, ProfilesModel) {
        let store = AccountStore(secureStore: InMemorySecureStore())
        let profiles = ProfilesModel(store: ProfileStore(defaults: makeDefaults()))
        let hub = AccountsProvidersModel(
            accountStore: store,
            registry: ProviderRegistry(),
            profilesModel: profiles
        )
        let plex = PlexHomeUsersModel(
            accountsProviders: hub,
            profilesModel: profiles,
            switchProfile: { _ in }
        )
        let settings = ProfileSettingsModel(namespace: profiles.activeNamespace)
        let model = ProfileFlowModel(
            profilesModel: profiles,
            accountsProviders: hub,
            plexHomeUsers: plex,
            profileSettings: settings,
            audioController: AudioPlaybackController(),
            updateTrackersForActiveProfile: {},
            discardWatchReconciler: { _ in }
        )
        return (model, profiles)
    }

    func testRequestAndCancelSelectionTogglePickerState() {
        let (model, _) = makeModel()
        XCTAssertFalse(model.isChoosingProfile)

        model.requestProfileSelection()
        XCTAssertTrue(model.isChoosingProfile)
        XCTAssertTrue(model.isProfileSelectionCancelable)

        model.cancelProfileSelection()
        XCTAssertFalse(model.isChoosingProfile)
    }

    func testPrepareLaunchPickerHiddenForSingleProfile() {
        let (model, _) = makeModel()
        // A brand-new household has one (default) profile → no launch picker,
        // and the launch picker is always mandatory (not cancelable).
        model.prepareLaunchPicker()
        XCTAssertFalse(model.isChoosingProfile)
        XCTAssertFalse(model.isProfileSelectionCancelable)
    }

    func testPrepareLaunchPickerShownWhenAskOnStartupWithMultipleProfiles() {
        let (model, profiles) = makeModel()
        profiles.enableProfiles()
        _ = profiles.add(name: "Second", avatarSymbol: "person", colorIndex: 1)
        profiles.setAskProfileOnStartup(true)

        model.prepareLaunchPicker()
        XCTAssertTrue(model.isChoosingProfile)
        XCTAssertFalse(model.isProfileSelectionCancelable)
    }

    func testFinishPickingThemeForNewProfileNoOpsWhenNotPicking() {
        let (model, _) = makeModel()
        // Not in the new-profile theme step → returns false and stays put.
        XCTAssertFalse(model.finishPickingThemeForNewProfile())
        XCTAssertFalse(model.isPickingThemeForNewProfile)
    }

    func testDismissPickerClearsChoosingState() {
        let (model, _) = makeModel()
        model.requestProfileSelection()
        XCTAssertTrue(model.isChoosingProfile)
        model.dismissPicker()
        XCTAssertFalse(model.isChoosingProfile)
    }
}
