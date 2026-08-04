import CoreModels
import Testing

@Suite("Server identity prompts")
struct ProfileServerIdentityPromptsTests {
    @Test("Enabling a Plex server with no binding asks who you are")
    func asksForPlex() {
        let prompts = ProfileServerIdentityPrompts()
        prompts.note(
            accountID: "a1",
            profileID: "kid",
            provider: .plex,
            hasExistingBinding: false
        )
        #expect(prompts.pendingAccountID(for: "kid") == "a1")
    }

    @Test("Non-Plex servers have no identity to choose, so nothing is asked")
    func skipsNonPlex() {
        let prompts = ProfileServerIdentityPrompts()
        for provider in [ProviderKind.jellyfin, .emby, .mediaShare] {
            prompts.note(
                accountID: "a1",
                profileID: "kid",
                provider: provider,
                hasExistingBinding: false
            )
        }
        #expect(prompts.pendingAccountID(for: "kid") == nil)
    }

    @Test("A profile that already picked a user isn't asked again")
    func skipsWhenAlreadyBound() {
        let prompts = ProfileServerIdentityPrompts()
        prompts.note(
            accountID: "a1",
            profileID: "kid",
            provider: .plex,
            hasExistingBinding: true
        )
        #expect(prompts.pendingAccountID(for: "kid") == nil)
    }

    @Test("Questions are per profile, not global")
    func scopedToProfile() {
        let prompts = ProfileServerIdentityPrompts()
        prompts.note(accountID: "a1", profileID: "kid", provider: .plex, hasExistingBinding: false)
        #expect(prompts.pendingAccountID(for: "grownup") == nil)
        #expect(prompts.pendingAccountID(for: "kid") == "a1")
    }

    @Test("Answering clears the question and moves to the next server")
    func resolvesInOrder() {
        let prompts = ProfileServerIdentityPrompts()
        prompts.note(accountID: "b", profileID: "kid", provider: .plex, hasExistingBinding: false)
        prompts.note(accountID: "a", profileID: "kid", provider: .plex, hasExistingBinding: false)
        // Stable order, not Set hashing — otherwise "answer one, get the next"
        // jumps around between launches.
        #expect(prompts.pendingAccountID(for: "kid") == "a")
        prompts.resolve(accountID: "a", profileID: "kid")
        #expect(prompts.pendingAccountID(for: "kid") == "b")
        prompts.resolve(accountID: "b", profileID: "kid")
        #expect(prompts.pendingAccountID(for: "kid") == nil)
    }

    @Test("Switching a server back off withdraws its question")
    func clearingProfileDropsQuestions() {
        let prompts = ProfileServerIdentityPrompts()
        prompts.note(accountID: "a1", profileID: "kid", provider: .plex, hasExistingBinding: false)
        prompts.clear(profileID: "kid")
        #expect(prompts.pendingAccountID(for: "kid") == nil)
    }
}
