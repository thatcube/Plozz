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
        #expect(profile.awaitsIdentity(amongAccounts: ["a1"]) == false)
    }

    @Test("An unanswered question defers the watchlist import")
    func pendingQuestionGatesImport() {
        var profile = makeProfile()
        let noted = profile.noteAccountAwaitingIdentity("a1")
        #expect(noted)
        // This is what the watchlist runtime reads to hold the native import
        // back — the question surviving in the record is the whole point.
        #expect(profile.awaitsIdentity(amongAccounts: ["a1"]))
    }

    @Test("A question about an account that isn't here gates nothing")
    func absentAccountDoesNotGate() {
        var profile = makeProfile()
        profile.noteAccountAwaitingIdentity("a1")
        // Questions are recorded generously — synced membership can enable a
        // server this device hasn't signed into yet — but an account that isn't
        // present has nothing to import from, so it must not defer the import
        // forever.
        #expect(profile.awaitsIdentity(amongAccounts: ["other"]) == false)
        #expect(profile.awaitsIdentity(amongAccounts: []) == false)
        // …and it starts gating the moment that account does arrive.
        #expect(profile.awaitsIdentity(amongAccounts: ["other", "a1"]))
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
        #expect(profile.awaitsIdentity(amongAccounts: ["a", "b"]) == false)
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
