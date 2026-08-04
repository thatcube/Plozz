import CoreModels
import Foundation

extension ProfilesModel {
    /// Creates a profile from an editor draft and marks it as awaiting setup.
    ///
    /// Shared by both shells on purpose. `add` takes fourteen arguments and does
    /// NOT know about `needsSetup`, so every caller had to remember to follow it
    /// with an `update` that set the flag — and the iOS shell didn't. A profile
    /// created without the flag is born holding every server, and the native
    /// watchlist import runs against all of them before the user has said who
    /// they're watching as: the household's aggregate watchlist lands in a brand
    /// new (often child) profile. Funnelling both shells through here makes that
    /// impossible to get wrong, and makes the flag part of creation rather than a
    /// second write that can be interrupted.
    ///
    /// - Parameter activeAccountIDs: the servers to seed. Setup narrows this;
    ///   until it finishes the import is gated regardless, so seeding broadly is
    ///   safe here.
    @discardableResult
    public func addAwaitingSetup(
        _ draft: ProfileDraft,
        isKids: Bool,
        activeAccountIDs: [String]
    ) -> Profile {
        let created = add(
            name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
            avatarSymbol: draft.avatarSymbol,
            colorIndex: draft.colorIndex,
            linkedAccountID: draft.linkedAccountID,
            activeAccountIDs: activeAccountIDs,
            plexHomeUserID: draft.plexHomeUserID,
            plexHomeUserName: draft.plexHomeUserName,
            plexHomeUserAccountID: draft.plexHomeUserAccountID,
            plexHomeUserRequiresPIN: draft.plexHomeUserRequiresPIN,
            plexHomeUserAvatarURL: draft.plexHomeUserAvatarURL,
            plexHomeUserBindings: draft.plexHomeUserBindings,
            avatarImageURL: draft.avatarImageURL,
            avatarEmoji: draft.avatarEmoji,
            avatarEmojiColorIndex: draft.avatarEmojiColorIndex
        )
        var configured = created
        configured.isKids = isKids
        configured.needsSetup = true
        update(configured)
        return configured
    }

    /// Clears the setup gate, returning `true` if it was actually set.
    ///
    /// `false` means someone else already completed setup for this profile (or it
    /// predates the gate), and the caller should NOT kick off a second import.
    @discardableResult
    public func finishSetup(for id: String) -> Bool {
        guard var profile = profiles.first(where: { $0.id == id }), profile.needsSetup else {
            return false
        }
        profile.needsSetup = false
        update(profile)
        return true
    }
}
