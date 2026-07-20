#if os(iOS)
import AppRuntime
import CoreModels
import CoreUI
import SwiftUI

struct PlozziOSPlexUserSelectionView: View {
    let selection: PlexHomeUsersModel.PendingPlexUserSelection
    let onSelect: (PlexHomeUser) -> Void

    private var orderedUsers: [PlexHomeUser] {
        selection.users.sorted { lhs, rhs in
            if lhs.isAdmin != rhs.isAdmin {
                return lhs.isAdmin
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(orderedUsers) { user in
                        Button {
                            onSelect(user)
                        } label: {
                            userRow(user)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Choose your user on \(selection.serverName).")
                } footer: {
                    Text("You can change this later in Settings.")
                }
            }
            .settingsPageSurface()
            .navigationTitle("Which Plex User Are You?")
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled()
    }

    private func userRow(_ user: PlexHomeUser) -> some View {
        HStack(spacing: 14) {
            AsyncImage(url: user.avatarURL) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .foregroundStyle(.secondary)
            }
            .frame(width: 48, height: 48)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(user.name)
                    .foregroundStyle(.primary)
                if user.isAdmin {
                    Text("Account Owner")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if user.requiresPIN {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Requires PIN")
            }
        }
        .contentShape(Rectangle())
    }
}
#endif
