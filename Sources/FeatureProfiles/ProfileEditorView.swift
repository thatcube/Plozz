#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// The edits collected by `ProfileEditorView`, handed back to the app so it can
/// create or update a profile and persist its account subset.
public struct ProfileDraft: Equatable, Sendable {
    /// `nil` when creating a new profile; the existing id when editing.
    public var id: String?
    public var name: String
    public var avatarSymbol: String
    public var colorIndex: Int
    /// Optional account this profile is *backed by* (Plex or Jellyfin).
    public var linkedAccountID: String?
    /// The account subset this profile uses (household account ids).
    public var activeAccountIDs: [String]
    /// The linked Plex Home user's `uuid` (when mapped), and cached metadata.
    public var plexHomeUserID: String?
    public var plexHomeUserName: String?
    public var plexHomeUserAccountID: String?
    public var plexHomeUserRequiresPIN: Bool?

    public init(
        id: String?,
        name: String,
        avatarSymbol: String,
        colorIndex: Int,
        linkedAccountID: String?,
        activeAccountIDs: [String],
        plexHomeUserID: String? = nil,
        plexHomeUserName: String? = nil,
        plexHomeUserAccountID: String? = nil,
        plexHomeUserRequiresPIN: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.avatarSymbol = avatarSymbol
        self.colorIndex = colorIndex
        self.linkedAccountID = linkedAccountID
        self.activeAccountIDs = activeAccountIDs
        self.plexHomeUserID = plexHomeUserID
        self.plexHomeUserName = plexHomeUserName
        self.plexHomeUserAccountID = plexHomeUserAccountID
        self.plexHomeUserRequiresPIN = plexHomeUserRequiresPIN
    }
}

/// Create / edit a profile on tvOS: name, avatar symbol, tile color, which
/// accounts back it, and an optional linked (Plex/Jellyfin) account.
public struct ProfileEditorView: View {
    private let editingProfile: Profile?
    private let accounts: [Account]
    private let canDelete: Bool
    private let onSave: (ProfileDraft) -> Void
    private let onDelete: (() -> Void)?
    private let onCancel: () -> Void
    /// Loads the Plex Home users for a given account id (async). `nil` hides the
    /// "Plex User" section (e.g. previews/tests without a Plex account).
    private let loadPlexHomeUsers: ((String) async -> [PlexHomeUser])?

    @State private var name: String
    @State private var avatarSymbol: String
    @State private var colorIndex: Int
    @State private var linkedAccountID: String?
    @State private var selectedAccountIDs: Set<String>
    @State private var plexHomeUserID: String?
    @State private var plexHomeUsers: [PlexHomeUser] = []
    @State private var isLoadingPlexUsers = false

    public init(
        editingProfile: Profile? = nil,
        accounts: [Account],
        selectedAccountIDs: [String],
        canDelete: Bool = false,
        loadPlexHomeUsers: ((String) async -> [PlexHomeUser])? = nil,
        onSave: @escaping (ProfileDraft) -> Void,
        onDelete: (() -> Void)? = nil,
        onCancel: @escaping () -> Void
    ) {
        self.editingProfile = editingProfile
        self.accounts = accounts
        self.canDelete = canDelete
        self.loadPlexHomeUsers = loadPlexHomeUsers
        self.onSave = onSave
        self.onDelete = onDelete
        self.onCancel = onCancel
        _name = State(initialValue: editingProfile?.name ?? "")
        _avatarSymbol = State(initialValue: editingProfile?.avatarSymbol ?? Profile.defaultAvatarSymbols[0])
        _colorIndex = State(initialValue: editingProfile?.colorIndex ?? 0)
        _linkedAccountID = State(initialValue: editingProfile?.linkedAccountID)
        _selectedAccountIDs = State(initialValue: Set(selectedAccountIDs))
        _plexHomeUserID = State(initialValue: editingProfile?.plexHomeUserID)
    }

    private var isEditing: Bool { editingProfile != nil }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool { !trimmedName.isEmpty }

    /// The "Backed by" account when it is a Plex login — the Home whose users we
    /// can map this profile to.
    private var linkedPlexAccount: Account? {
        guard let linkedAccountID else { return nil }
        return accounts.first { $0.id == linkedAccountID && $0.server.provider == .plex }
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Profile name", text: $name)
                }

                Section("Avatar") {
                    avatarGrid
                    colorRow
                    previewRow
                }

                if !accounts.isEmpty {
                    Section {
                        ForEach(accounts) { account in
                            accountToggle(account)
                        }
                    } header: {
                        Text("Accounts")
                    } footer: {
                        Text("Choose which signed-in servers this profile uses. With none selected, the profile uses all accounts.")
                    }

                    Section {
                        selectableRow(title: "None", selected: linkedAccountID == nil) {
                            linkedAccountID = nil
                        }
                        ForEach(accounts) { account in
                            selectableRow(
                                title: "\(account.userName) · \(account.server.provider.displayName)",
                                selected: linkedAccountID == account.id
                            ) {
                                linkedAccountID = account.id
                            }
                        }
                    } header: {
                        Text("Linked Account")
                    } footer: {
                        Text("Optionally tie this profile to a Plex or Jellyfin login. The linked account is included in the profile's accounts.")
                    }

                    if let plexAccount = linkedPlexAccount, loadPlexHomeUsers != nil {
                        plexUserSection(for: plexAccount)
                    }
                }

                if canDelete, let onDelete {
                    Section {
                        Button(role: .destructive, action: onDelete) {
                            Label("Delete Profile", systemImage: "trash")
                        }
                    }
                }
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 40)
            .navigationTitle(isEditing ? "Edit Profile" : "New Profile")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(!canSave)
                }
            }
        }
        .frame(minWidth: 1500, minHeight: 920)
    }

    private var avatarGrid: some View {
        let columns = [GridItem(.adaptive(minimum: 96, maximum: 120), spacing: 20)]
        return LazyVGrid(columns: columns, spacing: 20) {
            ForEach(Profile.defaultAvatarSymbols, id: \.self) { symbol in
                Button {
                    avatarSymbol = symbol
                } label: {
                    Image(systemName: symbol)
                        .font(.system(size: 48))
                        .frame(width: 96, height: 96)
                        .background(
                            Circle().fill(
                                symbol == avatarSymbol
                                ? ProfileTileColor.color(forIndex: colorIndex)
                                : Color.gray.opacity(0.25)
                            )
                        )
                        .foregroundStyle(symbol == avatarSymbol ? .white : .primary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 8)
    }

    private var colorRow: some View {
        let columns = [GridItem(.adaptive(minimum: 64, maximum: 80), spacing: 18)]
        return LazyVGrid(columns: columns, spacing: 18) {
            ForEach(0..<ProfileTileColor.palette.count, id: \.self) { index in
                Button {
                    colorIndex = index
                } label: {
                    Circle()
                        .fill(ProfileTileColor.color(forIndex: index))
                        .frame(width: 56, height: 56)
                        .overlay(
                            Circle().strokeBorder(.white, lineWidth: index == colorIndex ? 5 : 0)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 8)
    }

    private var previewRow: some View {
        HStack(spacing: 20) {
            ZStack {
                Circle().fill(ProfileTileColor.color(forIndex: colorIndex))
                Image(systemName: avatarSymbol)
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 96, height: 96)
            Text(trimmedName.isEmpty ? "Preview" : trimmedName)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func accountToggle(_ account: Account) -> some View {
        Button {
            if selectedAccountIDs.contains(account.id) {
                selectedAccountIDs.remove(account.id)
            } else {
                selectedAccountIDs.insert(account.id)
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(account.userName).font(.headline)
                    Text("\(account.server.name) · \(account.server.provider.displayName)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if selectedAccountIDs.contains(account.id) {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
        }
    }

    /// A tappable selection row that toggles a single-choice value inline (no
    /// navigation push — the pushed-picker style renders blank in a tvOS sheet).
    private func selectableRow(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if selected {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
        }
    }

    private func plexUserSection(for plexAccount: Account) -> some View {
        Section {
            if isLoadingPlexUsers {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Loading Plex users…").foregroundStyle(.secondary)
                }
            } else if plexHomeUsers.isEmpty {
                Text("No Plex Home users found for this account.")
                    .foregroundStyle(.secondary)
            } else {
                selectableRow(title: "None", selected: plexHomeUserID == nil) {
                    plexHomeUserID = nil
                }
                ForEach(plexHomeUsers) { user in
                    selectableRow(
                        title: user.requiresPIN ? "\(user.name)  🔒" : user.name,
                        selected: plexHomeUserID == user.id
                    ) {
                        plexHomeUserID = user.id
                    }
                }
            }
        } header: {
            Text("Plex User")
        } footer: {
            Text("Map this profile to a Plex Home user. Switching to this profile shows that user's library and watch state. PIN-protected users are asked for their PIN each time they're switched to.")
        }
        .task(id: plexAccount.id) { await loadUsers(for: plexAccount.id) }
    }

    private func loadUsers(for accountID: String) async {
        guard let loadPlexHomeUsers else { return }
        isLoadingPlexUsers = true
        let users = await loadPlexHomeUsers(accountID)
        plexHomeUsers = users
        isLoadingPlexUsers = false
        // Drop a stale selection no longer present in the fetched list.
        if let id = plexHomeUserID, !users.contains(where: { $0.id == id }) {
            plexHomeUserID = nil
        }
    }

    /// Resolves the Plex-user fields to persist, preserving an existing mapping
    /// when the Home-users list couldn't be (re)loaded.
    private func resolvedPlexFields() -> (id: String?, name: String?, account: String?, requiresPIN: Bool?) {
        guard let plexAccount = linkedPlexAccount, let id = plexHomeUserID else {
            return (nil, nil, nil, nil)
        }
        if let user = plexHomeUsers.first(where: { $0.id == id }) {
            return (id, user.name, plexAccount.id, user.requiresPIN)
        }
        if id == editingProfile?.plexHomeUserID {
            return (id, editingProfile?.plexHomeUserName, plexAccount.id, editingProfile?.plexHomeUserRequiresPIN)
        }
        return (id, nil, plexAccount.id, nil)
    }

    private func save() {
        var ids = selectedAccountIDs
        if let linkedAccountID { ids.insert(linkedAccountID) }
        let plex = resolvedPlexFields()
        onSave(ProfileDraft(
            id: editingProfile?.id,
            name: trimmedName,
            avatarSymbol: avatarSymbol,
            colorIndex: colorIndex,
            linkedAccountID: linkedAccountID,
            activeAccountIDs: Array(ids),
            plexHomeUserID: plex.id,
            plexHomeUserName: plex.name,
            plexHomeUserAccountID: plex.account,
            plexHomeUserRequiresPIN: plex.requiresPIN
        ))
    }
}
#endif
