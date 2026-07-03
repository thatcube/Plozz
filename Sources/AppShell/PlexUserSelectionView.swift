#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// "Which Plex user are you?" — shown after signing into a Plex account that has
/// two or more Home users, the first time a Plozz profile encounters that
/// account. The pick is remembered on the profile (as a Plex Home-user
/// binding), so it only appears again if the binding is cleared.
///
/// This names the *Plex Home user* to watch as on this server; it is distinct
/// from the Plozz profile picker ("Who's watching?"), which chooses the local
/// Plozz profile. A PIN-protected user is allowed here — the PIN is collected
/// later, when the binding is applied on entering the app.
///
/// Rows use the shared `PlexHomeUserRow` + `SettingsFocusButtonStyle`, so this
/// list is visually identical to the Settings → Plex User picker.
struct PlexUserSelectionView: View {
    let selection: AppState.PendingPlexUserSelection
    let onSelect: (PlexHomeUser) -> Void

    @FocusState private var focused: String?

    /// Account owner first (flagged), then everyone else — mirrors the Settings
    /// picker's ordering.
    private var orderedUsers: [PlexHomeUser] {
        let admins = selection.users.filter { $0.isAdmin }
        let others = selection.users.filter { !$0.isAdmin }
        return admins + others
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 14) {
                Text("Which Plex user are you?")
                    .font(.largeTitle.weight(.bold))
                    .multilineTextAlignment(.center)

                Text("Choose your user on \(selection.serverName).")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.bottom, 28)

            // Clipped scroll (no scrollClipDisabled) so rows never draw over the
            // pinned header/footer. Inner padding gives the focus fill (which
            // extends ~16pt H / 4pt V outward) and its shadow room at the edges.
            ScrollView {
                VStack(spacing: 14) {
                    ForEach(orderedUsers) { user in
                        Button {
                            onSelect(user)
                        } label: {
                            PlexHomeUserRow(user: user, showsOwnerBadge: user.isAdmin)
                        }
                        .buttonStyle(SettingsFocusButtonStyle())
                        .focused($focused, equals: user.id)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }

            Text("You can change this anytime in Settings.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 20)
        }
        .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
        .padding(.vertical, 48)
        .frame(maxWidth: 900)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .defaultFocus($focused, orderedUsers.first?.id)
    }
}
#endif
