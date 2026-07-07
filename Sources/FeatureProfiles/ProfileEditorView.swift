#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

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

    // Snapshot of the values this editor opened with, so Cancel/Menu can tell
    // whether anything actually changed and warn before discarding (issue: you
    // could edit everything then accidentally back out and silently lose it).
    private let initialName: String
    private let initialSymbol: String
    private let initialColorIndex: Int
    private let initialImageURL: String?

    @Environment(\.themePalette) private var palette

    @State private var name: String
    @State private var avatarSymbol: String
    @State private var colorIndex: Int
    @State private var avatarImageURL: String?
    @State private var avatarMode: AvatarMode
    @State private var photoCandidates: [ProfilePhotoCandidate] = []
    @State private var showDiscardConfirmation = false

    private enum AvatarMode: Hashable { case symbol, photo }

    public init(
        editingProfile: Profile? = nil,
        canDelete: Bool = false,
        photoSourceAccounts: [Account] = [],
        existingColorIndices: [Int] = [],
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

        let startName = editingProfile?.name ?? ""
        let startSymbol = editingProfile?.avatarSymbol ?? Profile.defaultAvatarSymbols[0]
        // New profiles pick the first colour not already used in the household,
        // so a lazy "just hit Save" doesn't leave everyone the same blue.
        let startColor = editingProfile?.colorIndex
            ?? Profile.suggestedColorIndex(existingColorIndices: existingColorIndices)
        let startPhoto = editingProfile?.avatarImageURL
        let normalizedPhoto = (startPhoto?.isEmpty == false) ? startPhoto : nil

        self.initialName = startName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.initialSymbol = startSymbol
        self.initialColorIndex = startColor
        self.initialImageURL = normalizedPhoto

        _name = State(initialValue: startName)
        _avatarSymbol = State(initialValue: startSymbol)
        _colorIndex = State(initialValue: startColor)
        _avatarImageURL = State(initialValue: normalizedPhoto)
        _avatarMode = State(initialValue: normalizedPhoto != nil ? .photo : .symbol)
    }

    private var isEditing: Bool { editingProfile != nil }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool { !trimmedName.isEmpty }

    /// The photo URL that would actually be saved right now — only meaningful in
    /// Photo mode (Symbol mode never persists a borrowed image).
    private var effectiveImageURL: String? {
        avatarMode == .photo ? avatarImageURL : nil
    }

    /// Whether any saveable field differs from what the editor opened with.
    /// Drives the "discard changes?" guard on Cancel / Menu.
    private var isDirty: Bool {
        trimmedName != initialName
            || avatarSymbol != initialSymbol
            || colorIndex != initialColorIndex
            || effectiveImageURL != initialImageURL
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                AppBackground(palette: palette).ignoresSafeArea()

                HStack(alignment: .top, spacing: 56) {
                    previewColumn
                    pickerColumn
                }
                .padding(.horizontal, 72)
                .padding(.top, 24)
            }
            .navigationTitle(isEditing ? "Edit Profile" : "New Profile")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: attemptCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(!canSave)
                }
            }
        }
        .frame(minWidth: 1500, minHeight: 920)
        .task { await loadPhotoCandidates() }
        .onChange(of: avatarMode) { _, newValue in
            // Leaving Photo mode drops any borrowed image so the symbol shows.
            if newValue == .symbol { avatarImageURL = nil }
        }
        // Intercept the Menu/back press so unsaved edits aren't silently lost.
        .onExitCommand(perform: attemptCancel)
        .alert("Discard changes?", isPresented: $showDiscardConfirmation) {
            Button("Discard", role: .destructive, action: onCancel)
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("You've made changes that haven't been saved. Going back now will lose them.")
        }
    }

    // MARK: Cancel / discard

    private func attemptCancel() {
        if isDirty {
            showDiscardConfirmation = true
        } else {
            onCancel()
        }
    }

    // MARK: Left column — always-visible live preview

    private var previewColumn: some View {
        VStack(spacing: 22) {
            Text("PREVIEW")
                .font(.caption.weight(.bold))
                .tracking(3)
                .foregroundStyle(palette.secondaryText)

            ProfileAvatarView(profile: previewProfile, size: 300)
                .shadow(color: .black.opacity(0.35), radius: 26, y: 14)

            Text(previewName)
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(palette.primaryText)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.6)

            Text(previewSubtitle)
                .font(.headline)
                .foregroundStyle(palette.secondaryText)
        }
        .frame(width: 460)
        .frame(maxHeight: .infinity)
    }

    private var previewProfile: Profile {
        Profile(
            id: editingProfile?.id ?? "preview",
            name: trimmedName,
            avatarSymbol: avatarSymbol,
            colorIndex: colorIndex,
            avatarImageURL: effectiveImageURL
        )
    }

    private var previewName: String {
        trimmedName.isEmpty ? (isEditing ? "Profile" : "New Profile") : trimmedName
    }

    private var previewSubtitle: String {
        if avatarMode == .photo {
            return effectiveImageURL != nil ? "Borrowed photo" : "No photo chosen yet"
        }
        return "Symbol avatar"
    }

    // MARK: Right column — scrolling editor

    private var pickerColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                nameSection
                avatarSection
                if canDelete, let onDelete {
                    deleteSection(onDelete)
                }
            }
            // Breathing room so the tiles' focus halos + shadows are never
            // clipped by the scroll view's edges.
            .padding(.horizontal, 28)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollClipDisabled()
    }

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Name")
            TextField("Profile name", text: $name)
                .textContentType(.name)
                .autocorrectionDisabled()
                .font(.title3)
        }
    }

    private var avatarSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            sectionHeader("Avatar")
            // A clear, legible mode switch — so it's obvious a photo is even an
            // option — instead of the old low-contrast segmented control.
            SettingsOptionPicker(
                options: [AvatarMode.symbol, AvatarMode.photo],
                selection: $avatarMode,
                icon: { $0 == .symbol ? "face.smiling" : "photo.fill" },
                title: { $0 == .symbol ? "Symbol" : "Photo" }
            )

            if avatarMode == .symbol {
                symbolCategoriesSection
                colorSection
            } else {
                photoSection
            }
        }
    }

    // MARK: Symbols

    private var symbolCategoriesSection: some View {
        let columns = [GridItem(.adaptive(minimum: 108, maximum: 128), spacing: 24)]
        return VStack(alignment: .leading, spacing: 28) {
            ForEach(Profile.avatarSymbolCategories) { category in
                VStack(alignment: .leading, spacing: 16) {
                    categoryHeader(category.title)
                    LazyVGrid(columns: columns, spacing: 24) {
                        ForEach(category.symbols, id: \.self) { symbol in
                            symbolTile(symbol)
                        }
                    }
                }
            }
        }
    }

    private func symbolTile(_ symbol: String) -> some View {
        let isSelected = symbol == avatarSymbol
        let diameter: CGFloat = 108
        return Button {
            avatarSymbol = symbol
        } label: {
            ZStack {
                Circle().fill(.ultraThinMaterial)
                Circle()
                    .fill(ProfileTileColor.color(forIndex: colorIndex))
                    .opacity(isSelected ? 1 : 0)
                Image(systemName: symbol)
                    .font(.system(size: 46, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.white : palette.primaryText)
            }
            .frame(width: diameter, height: diameter)
            .overlay {
                Circle()
                    .strokeBorder(Color.white.opacity(0.9), lineWidth: isSelected ? 3 : 0)
            }
        }
        .buttonStyle(CircularSelectionButtonStyle(diameter: diameter))
        .focusEffectDisabled()
        .accessibilityLabel(Text(symbol))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: Colors

    private var colorSection: some View {
        let columns = [GridItem(.adaptive(minimum: 68, maximum: 84), spacing: 22)]
        return VStack(alignment: .leading, spacing: 16) {
            categoryHeader("Color")
            LazyVGrid(columns: columns, spacing: 22) {
                ForEach(0..<ProfileTileColor.palette.count, id: \.self) { index in
                    colorSwatch(index)
                }
            }
        }
    }

    private func colorSwatch(_ index: Int) -> some View {
        let isSelected = index == colorIndex
        let diameter: CGFloat = 68
        return Button {
            colorIndex = index
        } label: {
            Circle()
                .fill(ProfileTileColor.color(forIndex: index))
                .frame(width: diameter, height: diameter)
                .overlay {
                    // Hairline so pale swatches still read against the surface.
                    Circle().strokeBorder(Color.black.opacity(0.12), lineWidth: 1)
                }
                .overlay {
                    Circle()
                        .strokeBorder(.white, lineWidth: isSelected ? 6 : 0)
                        .padding(3)
                }
        }
        .buttonStyle(CircularSelectionButtonStyle(diameter: diameter))
        .focusEffectDisabled()
        .accessibilityLabel(Text("Color \(index + 1)"))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: Photos

    /// Grid of borrowable photos sourced from signed-in Jellyfin users and
    /// Plex Home users that have a *real* photo (provider default silhouettes
    /// are filtered out upstream — see `ProfilePhotoCandidate`). Tapping one
    /// stamps its URL onto the draft's `avatarImageURL`.
    @ViewBuilder
    private var photoSection: some View {
        if photoCandidates.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Label("No photos to borrow yet", systemImage: "photo.on.rectangle")
                    .font(.headline)
                    .foregroundStyle(palette.primaryText)
                Text("Sign in to a Plex Home user or Jellyfin user that has a profile photo, then come back to use it here. In the meantime, a symbol works great.")
                    .font(.subheadline)
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    avatarMode = .symbol
                } label: {
                    Label("Use a symbol instead", systemImage: "face.smiling")
                }
                .buttonStyle(.bordered)
                .padding(.top, 6)
            }
            .padding(.vertical, 8)
        } else {
            let columns = [GridItem(.adaptive(minimum: 150, maximum: 184), spacing: 26)]
            LazyVGrid(columns: columns, spacing: 26) {
                ForEach(photoCandidates) { candidate in
                    Button {
                        avatarImageURL = candidate.imageURL.absoluteString
                    } label: {
                        PhotoTileLabel(
                            candidate: candidate,
                            isSelected: avatarImageURL == candidate.imageURL.absoluteString,
                            palette: palette
                        )
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                }
            }
        }
    }

    // MARK: Delete

    private func deleteSection(_ onDelete: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            categoryHeader("Delete")
            Button(role: .destructive, action: onDelete) {
                Label("Delete Profile", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            Text("Deleting a profile removes its preferences (theme, captions, spoilers, Trakt) and which servers it includes. Signed-in server accounts stay in the household pool.")
                .font(.footnote)
                .foregroundStyle(palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
    }

    // MARK: Section headers

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.title2.weight(.bold))
            .foregroundStyle(palette.primaryText)
    }

    private func categoryHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.subheadline.weight(.semibold))
            .tracking(1.5)
            .foregroundStyle(palette.secondaryText)
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

/// Circular focus treatment for the symbol / colour selection tiles: the app's
/// shared liquid-glass halo (`plozzFocusHalo`) blooming around the round tile on
/// focus, with a small press dip. Owning focus in a `ButtonStyle` (plus
/// `.focusEffectDisabled()` at the call site) means the ONLY focus visual is our
/// halo — no clipped white tvOS platter, which was the old grid's ugly-focus bug.
private struct CircularSelectionButtonStyle: ButtonStyle {
    let diameter: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        TileBody(configuration: configuration, diameter: diameter)
    }

    private struct TileBody: View {
        let configuration: ButtonStyle.Configuration
        let diameter: CGFloat
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .plozzFocusHalo(
                    cornerRadius: diameter / 2,
                    focusScale: PlozzTheme.Metrics.mediumFocusedCardScale,
                    isFocused: isFocused
                )
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}

/// A borrowable-photo tile: the round photo wearing the shared focus halo (read
/// off the enclosing button's `\.isFocused`) with the source labelled beneath.
/// Only the circle gets the halo — the caption stays put — so focus reads as a
/// clean ring around the photo, matching the symbol/colour tiles.
private struct PhotoTileLabel: View {
    let candidate: ProfilePhotoCandidate
    let isSelected: Bool
    let palette: ThemePalette
    @Environment(\.isFocused) private var isFocused

    private let diameter: CGFloat = 128

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(.ultraThinMaterial)
                FallbackAsyncImage(urls: [candidate.imageURL], variant: .posterCard) {
                    Image(systemName: "person.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(palette.secondaryText)
                }
                .frame(width: diameter, height: diameter)
                .clipShape(Circle())
                Circle()
                    .strokeBorder(palette.accent, lineWidth: isSelected ? 6 : 0)
            }
            .frame(width: diameter, height: diameter)
            .plozzFocusHalo(
                cornerRadius: diameter / 2,
                focusScale: PlozzTheme.Metrics.mediumFocusedCardScale,
                isFocused: isFocused
            )

            VStack(spacing: 2) {
                Text(candidate.providerLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.primaryText)
                Text(candidate.detailLabel)
                    .font(.caption2)
                    .foregroundStyle(palette.secondaryText)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
        }
    }
}
#endif
