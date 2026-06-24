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
    /// Optional opt-in profile photo URL (see `Profile.avatarImageURL`).
    /// When non-nil the avatar renders this image; nil falls back to the
    /// symbol + color combination.
    public var avatarImageURL: String?

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
        plexHomeUserBindings: [String: PlexHomeUserBinding]? = nil,
        avatarImageURL: String? = nil
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
        self.avatarImageURL = avatarImageURL
    }
}

/// Create / edit a profile's cosmetics on tvOS: name, avatar (symbol+color
/// OR an opt-in borrowed photo), and (when editing) a delete button.
///
/// Server-account membership and Plex Home-user mapping are deliberately
/// **not** in this view — they live in Settings → Servers & Libraries so
/// "what the profile looks like" is cleanly separated from "what the profile
/// can watch."
public struct ProfileEditorView: View {
    private let editingProfile: Profile?
    private let canDelete: Bool
    private let photoSourceAccounts: [Account]
    private let plexHomeUsersFetcher: (String) async -> [PlexHomeUser]
    private let onSave: (ProfileDraft) -> Void
    private let onDelete: (() -> Void)?
    private let onCancel: () -> Void

    @State private var name: String
    @State private var avatarSymbol: String
    @State private var colorIndex: Int
    @State private var avatarImageURL: String?
    @State private var avatarMode: AvatarMode
    @State private var photoCandidates: [ProfilePhotoCandidate] = []

    private enum AvatarMode: Hashable { case symbol, photo }

    public init(
        editingProfile: Profile? = nil,
        canDelete: Bool = false,
        photoSourceAccounts: [Account] = [],
        plexHomeUsersFetcher: @escaping (String) async -> [PlexHomeUser] = { _ in [] },
        onSave: @escaping (ProfileDraft) -> Void,
        onDelete: (() -> Void)? = nil,
        onCancel: @escaping () -> Void
    ) {
        self.editingProfile = editingProfile
        self.canDelete = canDelete
        self.photoSourceAccounts = photoSourceAccounts
        self.plexHomeUsersFetcher = plexHomeUsersFetcher
        self.onSave = onSave
        self.onDelete = onDelete
        self.onCancel = onCancel
        _name = State(initialValue: editingProfile?.name ?? "")
        _avatarSymbol = State(initialValue: editingProfile?.avatarSymbol ?? Profile.defaultAvatarSymbols[0])
        _colorIndex = State(initialValue: editingProfile?.colorIndex ?? 0)
        let initialPhoto = editingProfile?.avatarImageURL
        _avatarImageURL = State(initialValue: initialPhoto)
        _avatarMode = State(initialValue: (initialPhoto?.isEmpty == false) ? .photo : .symbol)
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
                    Picker("Avatar style", selection: $avatarMode) {
                        Text("Symbol").tag(AvatarMode.symbol)
                        Text("Photo").tag(AvatarMode.photo)
                    }
                    .pickerStyle(.segmented)

                    if avatarMode == .symbol {
                        avatarGrid
                        colorRow
                    } else {
                        photoSection
                    }
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
            .task { await loadPhotoCandidates() }
            .onChange(of: avatarMode) { _, newValue in
                if newValue == .symbol {
                    avatarImageURL = nil
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

    /// Grid of borrowable photos sourced from signed-in Jellyfin users and
    /// Plex Home users that have avatars. Tapping one stamps its URL onto
    /// the draft's `avatarImageURL`; "Use a symbol instead" reverts.
    @ViewBuilder
    private var photoSection: some View {
        if photoCandidates.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("No photos available to borrow")
                    .font(.headline)
                Text("Sign in to a Plex Home user or Jellyfin user with a profile photo, then come back to use it here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 12)
        } else {
            let columns = [GridItem(.adaptive(minimum: 128, maximum: 160), spacing: 22)]
            LazyVGrid(columns: columns, spacing: 22) {
                ForEach(photoCandidates) { candidate in
                    photoTile(candidate)
                }
            }
            .padding(.vertical, 8)
            Button {
                avatarMode = .symbol
                avatarImageURL = nil
            } label: {
                Label("Use a symbol instead", systemImage: "face.smiling")
            }
        }
    }

    private func photoTile(_ candidate: ProfilePhotoCandidate) -> some View {
        let isSelected = avatarImageURL == candidate.imageURL.absoluteString
        return Button {
            avatarImageURL = candidate.imageURL.absoluteString
        } label: {
            VStack(spacing: 8) {
                AsyncImage(url: candidate.imageURL) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().scaledToFill()
                    default:
                        ZStack {
                            Circle().fill(Color.gray.opacity(0.25))
                            Image(systemName: "person.fill")
                                .font(.system(size: 36))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(width: 112, height: 112)
                .clipShape(Circle())
                .overlay(
                    Circle().strokeBorder(
                        isSelected ? Color.accentColor : Color.clear,
                        lineWidth: 5
                    )
                )
                Text(candidate.providerLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(candidate.detailLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
        }
        .buttonStyle(.plain)
    }

    private var previewRow: some View {
        let previewProfile = Profile(
            id: editingProfile?.id ?? "preview",
            name: trimmedName,
            avatarSymbol: avatarSymbol,
            colorIndex: colorIndex,
            avatarImageURL: avatarImageURL
        )
        return HStack(spacing: 20) {
            ProfileAvatarView(profile: previewProfile, size: 96)
            Text(trimmedName.isEmpty ? "Preview" : trimmedName)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func loadPhotoCandidates() async {
        // Pull Plex Home users for every signed-in Plex account in parallel
        // so the photo grid has every borrowable face on first render.
        let plexAccounts = photoSourceAccounts.filter { $0.server.provider == .plex }
        var plexHomeUsersByAccount: [String: [PlexHomeUser]] = [:]
        await withTaskGroup(of: (String, [PlexHomeUser]).self) { group in
            for account in plexAccounts {
                let id = account.id
                let fetcher = plexHomeUsersFetcher
                group.addTask { (id, await fetcher(id)) }
            }
            for await (id, users) in group {
                plexHomeUsersByAccount[id] = users
            }
        }
        let candidates = ProfilePhotoCandidate.make(
            accounts: photoSourceAccounts,
            plexHomeUsersByAccount: plexHomeUsersByAccount
        )
        await MainActor.run { self.photoCandidates = candidates }
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
            plexHomeUserBindings: editingProfile?.plexHomeUserBindings,
            avatarImageURL: avatarMode == .photo ? avatarImageURL : nil
        ))
    }
}
#endif
