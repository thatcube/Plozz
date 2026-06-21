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

    public init(
        id: String?,
        name: String,
        avatarSymbol: String,
        colorIndex: Int,
        linkedAccountID: String?,
        activeAccountIDs: [String]
    ) {
        self.id = id
        self.name = name
        self.avatarSymbol = avatarSymbol
        self.colorIndex = colorIndex
        self.linkedAccountID = linkedAccountID
        self.activeAccountIDs = activeAccountIDs
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

    @State private var name: String
    @State private var avatarSymbol: String
    @State private var colorIndex: Int
    @State private var linkedAccountID: String?
    @State private var selectedAccountIDs: Set<String>

    public init(
        editingProfile: Profile? = nil,
        accounts: [Account],
        selectedAccountIDs: [String],
        canDelete: Bool = false,
        onSave: @escaping (ProfileDraft) -> Void,
        onDelete: (() -> Void)? = nil,
        onCancel: @escaping () -> Void
    ) {
        self.editingProfile = editingProfile
        self.accounts = accounts
        self.canDelete = canDelete
        self.onSave = onSave
        self.onDelete = onDelete
        self.onCancel = onCancel
        _name = State(initialValue: editingProfile?.name ?? "")
        _avatarSymbol = State(initialValue: editingProfile?.avatarSymbol ?? Profile.defaultAvatarSymbols[0])
        _colorIndex = State(initialValue: editingProfile?.colorIndex ?? 0)
        _linkedAccountID = State(initialValue: editingProfile?.linkedAccountID)
        _selectedAccountIDs = State(initialValue: Set(selectedAccountIDs))
    }

    private var isEditing: Bool { editingProfile != nil }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool { !trimmedName.isEmpty }

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
                        Picker("Backed by", selection: $linkedAccountID) {
                            Text("None").tag(String?.none)
                            ForEach(accounts) { account in
                                Text("\(account.userName) · \(account.server.provider.displayName)")
                                    .tag(String?.some(account.id))
                            }
                        }
                    } header: {
                        Text("Linked Account")
                    } footer: {
                        Text("Optionally tie this profile to a Plex or Jellyfin login. The linked account is included in the profile's accounts.")
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

    private func save() {
        var ids = selectedAccountIDs
        if let linkedAccountID { ids.insert(linkedAccountID) }
        onSave(ProfileDraft(
            id: editingProfile?.id,
            name: trimmedName,
            avatarSymbol: avatarSymbol,
            colorIndex: colorIndex,
            linkedAccountID: linkedAccountID,
            activeAccountIDs: Array(ids)
        ))
    }
}
#endif
