import CoreModels
import Foundation
import Testing

@Suite("Server identity prompts")
struct ProfileServerIdentityPromptsTests {
    private func makeProfile() -> Profile {
        Profile(name: "Kid")
    }

    @Test("Enabling a Plex server with no binding asks who you are")
    func asksForPlex() {
        #expect(
            ProfileServerIdentityPolicy.shouldAsk(provider: .plex, hasExistingBinding: false)
        )
    }

    @Test("Non-Plex servers have no identity to choose, so nothing is asked")
    func skipsNonPlex() {
        for provider in [ProviderKind.jellyfin, .emby, .mediaShare] {
            #expect(
                ProfileServerIdentityPolicy.shouldAsk(
                    provider: provider,
                    hasExistingBinding: false
                ) == false
            )
        }
    }

    @Test("A profile that already picked a user isn't asked again")
    func skipsWhenAlreadyBound() {
        #expect(
            ProfileServerIdentityPolicy.shouldAsk(provider: .plex, hasExistingBinding: true)
                == false
        )
    }

    @Test("A fresh profile owes nothing")
    func nothingPendingByDefault() {
        let profile = makeProfile()
        #expect(profile.pendingIdentityAccountIDs.isEmpty)
        #expect(profile.pendingIdentityAccountIDs.isEmpty)
    }

    @Test("An unanswered question defers the watchlist import")
    func pendingQuestionGatesImport() {
        var profile = makeProfile()
        let noted = profile.noteAccountAwaitingIdentity("a1")
        #expect(noted)
        // Recorded on the profile is the whole point: this is what the watchlist
        // runtime reads to hold the native import back, and it survives a restart.
        #expect(profile.pendingIdentityAccountIDs == ["a1"])
    }

    @Test("Noting the same account twice changes nothing")
    func noteIsIdempotent() {
        var profile = makeProfile()
        let first = profile.noteAccountAwaitingIdentity("a1")
        let second = profile.noteAccountAwaitingIdentity("a1")
        #expect(first)
        #expect(second == false)
        #expect(profile.pendingIdentityAccountIDs == ["a1"])
    }

    @Test("Questions are asked in a stable order across launches")
    func stableOrder() {
        var profile = makeProfile()
        profile.noteAccountAwaitingIdentity("b")
        profile.noteAccountAwaitingIdentity("a")
        #expect(profile.pendingIdentityAccountIDs == ["a", "b"])
    }

    @Test("Answering clears the question and moves to the next server")
    func resolvesInOrder() {
        var profile = makeProfile()
        profile.noteAccountAwaitingIdentity("b")
        profile.noteAccountAwaitingIdentity("a")
        let resolvedA = profile.resolveAccountAwaitingIdentity("a")
        #expect(resolvedA)
        #expect(profile.pendingIdentityAccountIDs == ["b"])
        let resolvedB = profile.resolveAccountAwaitingIdentity("b")
        #expect(resolvedB)
        #expect(profile.pendingIdentityAccountIDs.isEmpty)
    }

    @Test("The last answer clears to absence, not an empty array")
    func clearsToAbsence() {
        var profile = makeProfile()
        profile.noteAccountAwaitingIdentity("a1")
        profile.resolveAccountAwaitingIdentity("a1")
        // The sync layer requires records to round-trip byte-identically, and
        // `[]` is not the same bytes as no key at all.
        #expect(profile.accountsAwaitingIdentity == nil)
    }

    @Test("Resolving something that was never asked changes nothing")
    func resolveUnknownIsNoOp() {
        var profile = makeProfile()
        let resolved = profile.resolveAccountAwaitingIdentity("nope")
        #expect(resolved == false)
        #expect(profile.accountsAwaitingIdentity == nil)
    }

    @Test("The question survives an encode/decode round trip")
    func survivesPersistence() throws {
        var profile = makeProfile()
        profile.noteAccountAwaitingIdentity("a1")
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(Profile.self, from: data)
        // An in-memory question is forgotten on restart while the
        // enabled-but-unidentified server is still there — importing as the
        // owner on every launch.
        #expect(decoded.pendingIdentityAccountIDs == ["a1"])
    }
}

@MainActor
@Suite("Actionable identity questions")
struct ActionableIdentityQuestionsTests {
    private func makeModel() -> ProfilesModel {
        let defaults = UserDefaults(
            suiteName: "ActionableIdentityTests.\(UUID().uuidString)"
        )!
        return ProfilesModel(store: ProfileStore(defaults: defaults))
    }

    private func profileAwaiting(_ accountIDs: [String], in model: ProfilesModel) -> String {
        var profile = model.add(name: "Kid")
        for id in accountIDs { profile.noteAccountAwaitingIdentity(id) }
        model.update(profile)
        return profile.id
    }

    @Test("A recorded question about a locally present Plex server is actionable")
    func presentPlexAccountIsActionable() {
        let model = makeModel()
        let id = profileAwaiting(["a1"], in: model)
        #expect(
            model.actionableIdentityAccountIDs(forProfile: id, importAccountIDs: ["a1"])
                == ["a1"]
        )
    }

    @Test("A question about a server that isn't signed in here gates nothing")
    func absentAccountIsNotActionable() {
        let model = makeModel()
        let id = profileAwaiting(["a1"], in: model)
        // Questions are recorded generously — synced membership can enable a
        // server this device hasn't signed into — but an absent account has
        // nothing to import from, so it must not defer the import forever.
        #expect(
            model.actionableIdentityAccountIDs(forProfile: id, importAccountIDs: []).isEmpty
        )
    }

    @Test("An id that turns out not to be Plex gates nothing")
    func nonPlexIsNotActionable() {
        let model = makeModel()
        let id = profileAwaiting(["a1"], in: model)
        // Recorded when its provider was unknown; it arrived as Jellyfin, which
        // has no Home user to choose between.
        #expect(
            model.actionableIdentityAccountIDs(forProfile: id, importAccountIDs: ["b2"])
                .isEmpty
        )
    }

    @Test("A server the import won't read from gates nothing")
    func inactiveAccountIsNotActionable() {
        let model = makeModel()
        let id = profileAwaiting(["a1", "a2"], in: model)
        // The caller passes exactly what the import will fan out over, so a
        // server the profile no longer watches with simply isn't in the list.
        #expect(
            model.actionableIdentityAccountIDs(forProfile: id, importAccountIDs: ["a2"])
                == ["a2"]
        )
    }

    @Test("Whatever the import will read from is what gets gated")
    func gateFollowsTheImport() {
        let model = makeModel()
        let id = profileAwaiting(["a1"], in: model)
        // Deriving the set from stored membership instead looked equivalent and
        // wasn't: an explicitly empty selection reads as "no servers" while the
        // import falls back to the primary account, and imports as its owner.
        // Asking the import what it will actually do removes that second
        // definition — an empty explicit selection here still gates, because the
        // caller hands over the accounts the import resolved.
        model.setActiveAccountIDs([], for: id)
        #expect(
            model.actionableIdentityAccountIDs(forProfile: id, importAccountIDs: ["a1"])
                == ["a1"]
        )
    }

    @Test("The gate and the prompt agree on which question comes first")
    func gateAndPromptAgree() {
        let model = makeModel()
        // Sorted, and filtered identically, so the presenter can't pick an id the
        // gate counted but no screen can show — deferred forever, asked never.
        let id = profileAwaiting(["absent", "present"], in: model)
        let actionable = model.actionableIdentityAccountIDs(
            forProfile: id,
            importAccountIDs: ["present"]
        )
        #expect(actionable == ["present"])
        #expect(actionable.first == "present")
    }
}
