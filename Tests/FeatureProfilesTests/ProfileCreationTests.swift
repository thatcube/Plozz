import CoreModels
import FeatureProfiles
import Foundation
import Testing

@MainActor
@Suite("Gated profile creation")
struct ProfileCreationTests {
    private func makeModel() -> ProfilesModel {
        let defaults = UserDefaults(
            suiteName: "ProfileCreationTests.\(UUID().uuidString)"
        )!
        return ProfilesModel(store: ProfileStore(defaults: defaults))
    }

    private func makeDraft(name: String = "Kid") -> ProfileDraft {
        ProfileDraft(
            id: nil,
            name: name,
            avatarSymbol: Profile.defaultAvatarSymbols[0],
            colorIndex: 0
        )
    }

    @Test("A new profile is born awaiting setup, so nothing imports yet")
    func createdAwaitingSetup() {
        let model = makeModel()
        let created = model.addAwaitingSetup(makeDraft(), isKids: false, activeAccountIDs: ["a1"])
        // The whole point: until this clears, the watchlist import is gated and
        // the profile can't inherit the household's aggregate list.
        #expect(created.needsSetup)
        #expect(model.profiles.first { $0.id == created.id }?.needsSetup == true)
    }

    @Test("The stored record carries the flag, not just the returned value")
    func flagIsPersisted() {
        let model = makeModel()
        let created = model.addAwaitingSetup(makeDraft(), isKids: true, activeAccountIDs: [])
        let stored = model.profiles.first { $0.id == created.id }
        #expect(stored?.needsSetup == true)
        #expect(stored?.isKids == true)
    }

    @Test("Names are trimmed at creation")
    func trimsName() {
        let model = makeModel()
        let created = model.addAwaitingSetup(
            makeDraft(name: "  Kid  "),
            isKids: false,
            activeAccountIDs: []
        )
        #expect(created.name == "Kid")
    }

    @Test("Finishing setup lifts the gate exactly once")
    func finishSetupIsIdempotent() {
        let model = makeModel()
        let created = model.addAwaitingSetup(makeDraft(), isKids: false, activeAccountIDs: [])
        #expect(model.finishSetup(for: created.id))
        #expect(model.profiles.first { $0.id == created.id }?.needsSetup == false)
        // A second call must report false: the caller uses the return value to
        // decide whether to kick off the import, and running it twice would race
        // two imports against each other.
        #expect(model.finishSetup(for: created.id) == false)
    }

    @Test("Finishing setup on an unknown profile is a no-op")
    func finishSetupUnknownProfile() {
        let model = makeModel()
        #expect(model.finishSetup(for: "nope") == false)
    }
}
