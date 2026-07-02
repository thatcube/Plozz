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
struct PlexUserSelectionView: View {
    let selection: AppState.PendingPlexUserSelection
    let onSelect: (PlexHomeUser) -> Void

    @Environment(\.themePalette) private var palette
    @FocusState private var focused: String?

    private let columns = [GridItem(.adaptive(minimum: 240, maximum: 300), spacing: 48)]

    var body: some View {
        VStack(spacing: 40) {
            VStack(spacing: 14) {
                Text("Which Plex user are you?")
                    .font(.largeTitle.weight(.bold))
                    .multilineTextAlignment(.center)

                Text("Choose your user on \(selection.serverName).")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            ScrollView {
                LazyVGrid(columns: columns, spacing: 48) {
                    ForEach(selection.users) { user in
                        userTile(user)
                    }
                }
                // Horizontal gutters so the focused tile's ring/scale never
                // clips against the width-constrained content edges.
                .padding(.horizontal, 24)
                .padding(.vertical, 24)
            }

            Text("You can change this anytime in Settings.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
        .padding(.vertical, 48)
        .frame(maxWidth: 1100)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .defaultFocus($focused, selection.users.first?.id)
    }

    private func userTile(_ user: PlexHomeUser) -> some View {
        let isFocused = focused == user.id
        return Button {
            onSelect(user)
        } label: {
            VStack(spacing: 18) {
                ZStack(alignment: .bottomTrailing) {
                    avatar(for: user)
                        .frame(width: 200, height: 200)
                        .clipShape(Circle())
                        .overlay(
                            Circle().strokeBorder(
                                isFocused ? palette.accent : Color.primary.opacity(0.12),
                                lineWidth: isFocused ? 6 : 2
                            )
                        )

                    if user.requiresPIN {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(14)
                            .background(Circle().fill(palette.accent))
                            .overlay(Circle().strokeBorder(Color.black.opacity(0.25), lineWidth: 2))
                    }
                }
                .scaleEffect(isFocused ? 1.06 : 1)
                .shadow(color: .black.opacity(isFocused ? 0.3 : 0), radius: isFocused ? 16 : 0, y: isFocused ? 8 : 0)

                Text(user.name)
                    .font(.title3.weight(isFocused ? .semibold : .regular))
                    .foregroundStyle(isFocused ? Color.primary : Color.secondary)
                    .lineLimit(1)
            }
            .animation(.easeOut(duration: 0.16), value: isFocused)
        }
        .buttonStyle(.plain)
        .focused($focused, equals: user.id)
    }

    @ViewBuilder
    private func avatar(for user: PlexHomeUser) -> some View {
        if let url = user.avatarURL {
            FallbackAsyncImage(urls: [url], variant: .posterCard) {
                avatarPlaceholder(for: user)
            }
        } else {
            avatarPlaceholder(for: user)
        }
    }

    private func avatarPlaceholder(for user: PlexHomeUser) -> some View {
        ZStack {
            Circle().fill(Color.secondary.opacity(0.25))
            Text(initial(for: user))
                .font(.system(size: 88, weight: .semibold))
                .foregroundStyle(.white)
        }
    }

    private func initial(for user: PlexHomeUser) -> String {
        let trimmed = user.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.first.map { String($0).uppercased() } ?? "?"
    }
}
#endif
