#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// The edits collected by `ProfileEditorView`, handed back to the app so it
/// can create or update a profile.
///
/// Account selection and Plex Home-user mapping no longer live in the editor
/// — they moved out to Settings → Servers & Libraries → per-server details.
/// The fields are still on the draft so callers can preserve them across an
/// update (e.g. Settings carries the existing values through unchanged).
public struct ProfileDraft: Equatable, Sendable {
    /// `nil` when creating a new profile; the existing id when editing.
    public var id: String?
    public var name: String
    public var avatarSymbol: String
    public var colorIndex: Int
    /// Optional account this profile is *backed by* (Plex or Jellyfin). Kept
    /// on the draft for callers that want to preserve it; not editable here.
    public var linkedAccountID: String?
    /// The account subset this profile uses. Kept on the draft for callers
    /// that want to preserve it; not editable here. Settings → Servers &
    /// Libraries is the new authoritative surface for this.
    public var activeAccountIDs: [String]
    /// Plex Home user fields. Kept on the draft for callers that want to
    /// preserve them; not editable here. Settings → Servers & Libraries →
    /// Plex server is the new authoritative surface.
    public var plexHomeUserID: String?
    public var plexHomeUserName: String?
    public var plexHomeUserAccountID: String?
    public var plexHomeUserRequiresPIN: Bool?
    public var plexHomeUserAvatarURL: String?
    /// Per–Plex-account Home-user mappings (see `Profile.plexHomeUserBindings`).
    public var plexHomeUserBindings: [String: PlexHomeUserBinding]?

    public init(
        id: String?,
        name: String,
        avatarSymbol: String,
        colorIndex: Int,
        linkedAccountID: String? = nil,
        activeAccountIDs: [String] = [],
        plexHomeUserID: String? = nil,
        plexHomeUserName: String? = nil,
        plexHomeUserAccountID: String? = nil,
        plexHomeUserRequiresPIN: Bool? = nil,
        plexHomeUserAvatarURL: String? = nil,
        plexHomeUserBindings: [String: PlexHomeUserBinding]? = nil
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
        self.plexHomeUserAvatarURL = plexHomeUserAvatarURL
        self.plexHomeUserBindings = plexHomeUserBindings
    }
}

/// Create / edit a profile's cosmetics on tvOS: name, avatar symbol, tile
/// color, and (when editing) a delete button.
///
/// Server-account membership and Plex Home-user mapping are deliberately
/// **not** in this view — they live in Settings → Servers & Libraries so
/// "what the profile looks like" is cleanly separated from "what the profile
/// can watch."
public struct ProfileEditorView: View {
    private let editingProfile: Profile?
    private let canDelete: Bool
    private let onSave: (ProfileDraft) -> Void
    private let onDelete: (() -> Void)?
    private let onCancel: () -> Void

    @State private var name: String
    @State private var avatarSymbol: String
    @State private var colorIndex: Int

    public init(
        editingProfile: Profile? = nil,
        canDelete: Bool = false,
        onSave: @escaping (ProfileDraft) -> Void,
        onDelete: (() -> Void)? = nil,
        onCancel: @escaping () -> Void
    ) {
        self.editingProfile = editingProfile
        self.canDelete = canDelete
        self.onSave = onSave
        self.onDelete = onDelete
        self.onCancel = onCancel
        _name = State(initialValue: editingProfile?.name ?? "")
        _avatarSymbol = State(initialValue: editingProfile?.avatarSymbol ?? Profile.defaultAvatarSymbols[0])
        _colorIndex = State(initialValue: editingProfile?.colorIndex ?? 0)
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

                if canDelete, let onDelete {
                    Section {
                        Button(role: .destructive, action: onDelete) {
                            Label("Delete Profile", systemImage: "trash")
                        }
                    } footer: {
                        Text("Deleting a profile removes its preferences (theme, captions, spoilers, Trakt) and which servers it includes. Signed-in server accounts stay in the household pool.")
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

    private func save() {
        // Carry through the existing non-cosmetic fields so callers that
        // dispatch a single `saveProfile(draft)` path don't accidentally wipe
        // server membership or Plex Home-user mapping when only cosmetics
        // changed.
        onSave(ProfileDraft(
            id: editingProfile?.id,
            name: trimmedName,
            avatarSymbol: avatarSymbol,
            colorIndex: colorIndex,
            linkedAccountID: editingProfile?.linkedAccountID,
            activeAccountIDs: [],
            plexHomeUserID: editingProfile?.plexHomeUserID,
            plexHomeUserName: editingProfile?.plexHomeUserName,
            plexHomeUserAccountID: editingProfile?.plexHomeUserAccountID,
            plexHomeUserRequiresPIN: editingProfile?.plexHomeUserRequiresPIN,
            plexHomeUserAvatarURL: editingProfile?.plexHomeUserAvatarURL,
            plexHomeUserBindings: editingProfile?.plexHomeUserBindings
        ))
    }
}
#endif
