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
    /// Optional emoji avatar (see `Profile.avatarEmoji`). When non-nil the
    /// avatar renders this emoji on the colored tile; wins over the symbol but
    /// loses to a photo.
    public var avatarEmoji: String?
    /// Optional background colour for an emoji avatar (see
    /// `Profile.avatarEmojiColorIndex`). `nil` = neutral disc (default).
    public var avatarEmojiColorIndex: Int?

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
        avatarImageURL: String? = nil,
        avatarEmoji: String? = nil,
        avatarEmojiColorIndex: Int? = nil
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
        self.avatarEmoji = avatarEmoji
        self.avatarEmojiColorIndex = avatarEmojiColorIndex
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
    /// When provided (and editing an existing profile), the editor **auto-saves**:
    /// every cosmetic change is pushed here live, Cancel/Save is replaced with
    /// Done + Revert, and backing out keeps the work. Hosts wire this to a
    /// cosmetics-only persistence path. `nil` keeps the classic explicit-Save
    /// flow (used for brand-new profiles and first-run setup).
    private let onLiveChange: ((ProfileDraft) -> Void)?

    // Snapshot of the values this editor opened with — drives Revert (and, in
    // the explicit-Save flow, the discard warning).
    private let initialName: String
    private let initialSymbol: String
    private let initialColorIndex: Int
    private let initialImageURL: String?
    private let initialEmoji: String?
    private let initialEmojiColorIndex: Int?
    private let initialMode: AvatarMode

    @Environment(\.themePalette) private var palette

    @State private var name: String
    @State private var avatarSymbol: String
    @State private var colorIndex: Int
    @State private var avatarImageURL: String?
    @State private var avatarEmoji: String?
    /// nil = neutral disc behind the emoji (default); a value = palette colour.
    @State private var emojiColorIndex: Int?
    @State private var avatarMode: AvatarMode
    @State private var photoCandidates: [ProfilePhotoCandidate] = []
    @State private var showDiscardConfirmation = false
    @State private var showDeleteConfirmation = false

    private enum AvatarMode: Hashable { case symbol, emoji, photo }

    /// Current tvOS version, so the emoji picker can hide glyphs the device is
    /// too old to render (they'd otherwise show as empty "tofu" boxes).
    private let osVersion = ProcessInfo.processInfo.operatingSystemVersion

    public init(
        editingProfile: Profile? = nil,
        canDelete: Bool = false,
        photoSourceAccounts: [Account] = [],
        existingColorIndices: [Int] = [],
        plexHomeUsersFetcher: @escaping (String) async -> [PlexHomeUser] = { _ in [] },
        onSave: @escaping (ProfileDraft) -> Void,
        onLiveChange: ((ProfileDraft) -> Void)? = nil,
        onDelete: (() -> Void)? = nil,
        onCancel: @escaping () -> Void
    ) {
        self.editingProfile = editingProfile
        self.canDelete = canDelete
        self.photoSourceAccounts = photoSourceAccounts
        self.plexHomeUsersFetcher = plexHomeUsersFetcher
        self.onSave = onSave
        self.onLiveChange = onLiveChange
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
        let startEmoji = editingProfile?.avatarEmoji
        var normalizedEmoji = (startEmoji?.isEmpty == false) ? startEmoji : nil
        // A brand-new profile starts on a fun *random* emoji, so simply hitting
        // Create (without opening the picker) still yields an emoji avatar
        // rather than a plain symbol.
        if editingProfile == nil, normalizedEmoji == nil {
            normalizedEmoji = Profile.randomAvatarEmoji()
        }
        let startEmojiColor = editingProfile?.avatarEmojiColorIndex

        // Open in the mode that matches the profile's current avatar. A NEW
        // profile (nothing set yet) defaults to Emoji — the funnest, most
        // expressive option and the one we want people to reach for first.
        let startMode: AvatarMode
        if normalizedPhoto != nil {
            startMode = .photo
        } else if normalizedEmoji != nil {
            startMode = .emoji
        } else if editingProfile != nil {
            startMode = .symbol
        } else {
            startMode = .emoji
        }

        self.initialName = startName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.initialSymbol = startSymbol
        self.initialColorIndex = startColor
        self.initialImageURL = normalizedPhoto
        self.initialEmoji = normalizedEmoji
        self.initialEmojiColorIndex = startEmojiColor
        self.initialMode = startMode

        _name = State(initialValue: startName)
        _avatarSymbol = State(initialValue: startSymbol)
        _colorIndex = State(initialValue: startColor)
        _avatarImageURL = State(initialValue: normalizedPhoto)
        _avatarEmoji = State(initialValue: normalizedEmoji)
        _emojiColorIndex = State(initialValue: startEmojiColor)
        _avatarMode = State(initialValue: startMode)
    }

    private var isEditing: Bool { editingProfile != nil }
    /// Auto-save mode: an existing profile whose host wired a live-change hook.
    private var autoSaves: Bool { isEditing && onLiveChange != nil }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool { !trimmedName.isEmpty }

    /// The photo URL that would actually be saved right now — only meaningful in
    /// Photo mode.
    private var effectiveImageURL: String? {
        avatarMode == .photo ? avatarImageURL : nil
    }

    /// The emoji that would actually be saved right now — only meaningful in
    /// Emoji mode.
    private var effectiveEmoji: String? {
        avatarMode == .emoji ? avatarEmoji : nil
    }

    /// The emoji background colour that would be saved — only meaningful for an
    /// emoji avatar; nil = the neutral disc.
    private var effectiveEmojiColorIndex: Int? {
        avatarMode == .emoji ? emojiColorIndex : nil
    }

    /// Whether the colour picker is relevant for the current mode. Symbol and
    /// emoji avatars both offer a colour (emoji adds a Neutral option); a
    /// borrowed photo ignores it.
    private var colorApplies: Bool { avatarMode != .photo }

    /// The draft the current UI state represents.
    private var currentDraft: ProfileDraft {
        ProfileDraft(
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
            avatarImageURL: effectiveImageURL,
            avatarEmoji: effectiveEmoji,
            avatarEmojiColorIndex: effectiveEmojiColorIndex
        )
    }

    /// Whether any saveable field differs from what the editor opened with.
    private var isDirty: Bool {
        trimmedName != initialName
            || avatarSymbol != initialSymbol
            || colorIndex != initialColorIndex
            || effectiveImageURL != initialImageURL
            || effectiveEmoji != initialEmoji
            || effectiveEmojiColorIndex != initialEmojiColorIndex
    }

    public var body: some View {
        ZStack {
            AppBackground(palette: palette).ignoresSafeArea()

            HStack(alignment: .top, spacing: 48) {
                // Marking each column a focus SECTION makes Left/Right move
                // between columns as a whole, instead of the focus engine
                // hunting for the geometrically-nearest control. Without this,
                // once you scroll deep into the symbol wall a Left press finds
                // no colour swatch at that Y and focus just won't cross over.
                previewColumn
                    .focusSection()
                // Full-height hairline separating the fixed preview/colour
                // column from the scrolling picker.
                Rectangle()
                    .fill(palette.cardBorder)
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
                pickerColumn
                    .focusSection()
            }
            .padding(.horizontal, 72)
            .padding(.vertical, 24)
        }
        .frame(minWidth: 1720, minHeight: 960)
        .task { await loadPhotoCandidates() }
        // Live auto-save (existing profiles): push every cosmetic change through.
        .onChange(of: currentDraft) { _, draft in
            if autoSaves { onLiveChange?(draft) }
        }
        // Menu/back: in auto-save mode nothing is lost, so just close. In the
        // explicit-Save flow, warn before discarding unsaved edits.
        .onExitCommand(perform: handleExit)
        .alert("Discard changes?", isPresented: $showDiscardConfirmation) {
            Button("Discard", role: .destructive, action: onCancel)
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("You've made changes that haven't been saved. Going back now will lose them.")
        }
        .alert("Delete this profile?", isPresented: $showDeleteConfirmation) {
            Button("Delete Profile", role: .destructive) { onDelete?() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deleting removes this profile's preferences (theme, captions, spoilers, Trakt) and which servers it includes. Signed-in server accounts stay in the household pool.")
        }
    }

    /// Title + the trailing actions. In auto-save mode: **Done** (just close —
    /// everything is already saved) + **Revert All Changes** (one press restores
    /// exactly how the profile was when you opened it). In explicit-Save mode
    /// (new profile / first-run): **Cancel** + **Save**. Scrolls with the page.
    private var headerRow: some View {
        HStack(alignment: .center, spacing: 20) {
            // Delete lives here as a prominent, icon-only destructive action
            // (only for profiles that can be removed — never the primary one),
            // so it's discoverable without cluttering the picker and can't be
            // hit while scrolling. It always confirms first.
            if canDelete, onDelete != nil {
                deleteButton
            }
            Text(isEditing ? "Edit Profile" : "New Profile")
                .font(.system(size: 44, weight: .bold))
                .foregroundStyle(palette.primaryText)
            Spacer(minLength: 24)
            if autoSaves {
                Button("Revert All Changes", action: revertAll)
                    .plozzGlassPillButton()
                    .focusEffectDisabled()
                    .disabled(!isDirty)
                Button("Done", action: onCancel)
                    .plozzGlassPillButton(isSelected: true)
                    .focusEffectDisabled()
            } else {
                Button("Cancel", action: attemptCancel)
                    .plozzGlassPillButton()
                    .focusEffectDisabled()
                Button(isEditing ? "Save" : "Create", action: save)
                    .plozzGlassPillButton(isSelected: true)
                    .focusEffectDisabled()
                    .disabled(!canSave)
            }
        }
    }

    /// Icon-only destructive trash button for the header. A red glyph on a
    /// circular chip wearing the shared focus halo (same treatment as the
    /// avatar tiles), so it reads as destructive and focuses consistently.
    private var deleteButton: some View {
        let diameter: CGFloat = 60
        return Button {
            showDeleteConfirmation = true
        } label: {
            ZStack {
                Circle().fill(palette.cardSurface)
                Image(systemName: "trash")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.red)
            }
            .frame(width: diameter, height: diameter)
            .overlay { Circle().strokeBorder(palette.cardBorder, lineWidth: 1) }
        }
        .buttonStyle(CircularSelectionButtonStyle(diameter: diameter))
        .focusEffectDisabled()
        .accessibilityLabel(Text("Delete Profile"))
    }

    // MARK: Exit / discard / revert

    private func handleExit() {
        // Auto-save mode: work is already persisted, so backing out just closes.
        if autoSaves { onCancel() } else { attemptCancel() }
    }

    private func attemptCancel() {
        if isDirty {
            showDiscardConfirmation = true
        } else {
            onCancel()
        }
    }

    /// Restore every field to the snapshot the editor opened with — a single,
    /// all-at-once revert (not a step-by-step undo). In auto-save mode the
    /// `onChange` above then persists the restored values.
    private func revertAll() {
        name = initialName
        avatarSymbol = initialSymbol
        colorIndex = initialColorIndex
        avatarImageURL = initialImageURL
        avatarEmoji = initialEmoji
        emojiColorIndex = initialEmojiColorIndex
        avatarMode = initialMode
    }

    // MARK: Left column — always-visible live preview + colour

    private var previewColumn: some View {
        VStack(alignment: .leading, spacing: 32) {
            VStack(spacing: 18) {
                Text("PREVIEW")
                    .font(.caption.weight(.bold))
                    .tracking(3)
                    .foregroundStyle(palette.secondaryText)

                // Roughly the size the avatar actually renders at elsewhere —
                // enough to judge the choice without dominating the screen.
                ProfileAvatarView(profile: previewProfile, size: 160)
                    .shadow(color: .black.opacity(0.3), radius: 20, y: 10)

                Text(previewName)
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(palette.primaryText)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)

                Text(previewSubtitle)
                    .font(.headline)
                    .foregroundStyle(palette.secondaryText)
            }
            .frame(maxWidth: .infinity)

            // Colour lives here — high up beside the live preview, not buried at
            // the bottom of the scrolling picker — so it reads as prominent and
            // you can watch the avatar recolour as you pick. Symbol AND emoji
            // avatars sit on the coloured disc; a borrowed photo ignores it.
            if colorApplies {
                colorSection
            }
        }
        .frame(width: 460, alignment: .leading)
    }

    private var previewProfile: Profile {
        Profile(
            id: editingProfile?.id ?? "preview",
            name: trimmedName,
            avatarSymbol: avatarSymbol,
            colorIndex: colorIndex,
            avatarImageURL: effectiveImageURL,
            avatarEmoji: effectiveEmoji,
            avatarEmojiColorIndex: effectiveEmojiColorIndex
        )
    }

    private var previewName: String {
        trimmedName.isEmpty ? (isEditing ? "Profile" : "New Profile") : trimmedName
    }

    private var previewSubtitle: String {
        switch avatarMode {
        case .photo:
            return effectiveImageURL != nil ? "Borrowed photo" : "No photo chosen yet"
        case .emoji:
            return "Emoji avatar"
        case .symbol:
            return "Symbol avatar"
        }
    }

    // MARK: Right column — scrolling editor

    private var pickerColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                headerRow
                nameSection
                avatarSection
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
            // A clear, legible mode switch — so it's obvious emoji and photo are
            // even options — instead of the old low-contrast segmented control.
            SettingsOptionPicker(
                options: [AvatarMode.emoji, AvatarMode.photo, AvatarMode.symbol],
                selection: $avatarMode,
                icon: { mode in
                    switch mode {
                    case .emoji: return "face.dashed"
                    case .photo: return "photo.fill"
                    case .symbol: return "face.smiling"
                    }
                },
                title: { mode in
                    switch mode {
                    case .emoji: return "Emoji"
                    case .photo: return "Photo"
                    case .symbol: return "Symbol"
                    }
                }
            )

            switch avatarMode {
            case .symbol: symbolCategoriesSection
            case .emoji: emojiCategoriesSection
            case .photo: photoSection
            }
        }
    }

    // MARK: Symbols

    private var symbolCategoriesSection: some View {
        VStack(alignment: .leading, spacing: 28) {
            ForEach(Profile.avatarSymbolCategories) { category in
                VStack(alignment: .leading, spacing: 16) {
                    categoryHeader(category.title)
                    symbolRows(for: category.symbols)
                }
            }
        }
    }

    /// Renders a category's symbols as eager rows of 8. Deliberately NOT a
    /// `LazyVGrid`: a lazy grid rebuilds cells as they enter/leave the viewport,
    /// so a row would blank out ("disappear then reappear") as it scrolled near
    /// the dialog's top edge. A plain `VStack`/`HStack` keeps every tile built,
    /// and fixing 8 per row means each 8-symbol category is exactly one clean
    /// line.
    @ViewBuilder
    private func symbolRows(for symbols: [String]) -> some View {
        let perRow = 8
        let rows = stride(from: 0, to: symbols.count, by: perRow).map {
            Array(symbols[$0..<min($0 + perRow, symbols.count)])
        }
        VStack(spacing: 18) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 18) {
                    ForEach(row, id: \.self) { symbol in
                        symbolTile(symbol).frame(maxWidth: .infinity)
                    }
                    // Hold column width on a partial last row so its tiles keep
                    // the same size as full rows instead of stretching.
                    if row.count < perRow {
                        ForEach(0..<(perRow - row.count), id: \.self) { _ in
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
    }

    private func symbolTile(_ symbol: String) -> some View {
        let isSelected = symbol == avatarSymbol
        let diameter: CGFloat = 92
        return Button {
            avatarSymbol = symbol
        } label: {
            ZStack {
                // Theme-aware resting surface (never a stray white material):
                // the selected tile fills with the chosen avatar colour exactly
                // as it will render, otherwise a subtle themed card circle.
                Circle().fill(isSelected
                    ? AnyShapeStyle(ProfileTileColor.color(forIndex: colorIndex))
                    : AnyShapeStyle(palette.cardSurface))
                Image(systemName: symbol)
                    .font(.system(size: 46, weight: .semibold))
                    // On the selected coloured disc the glyph adapts to the
                    // colour (dark on white/yellow, white on dark) so it stays
                    // legible; unselected uses the theme's primary text.
                    .foregroundStyle(isSelected
                        ? ProfileTileColor.legibleForeground(forIndex: colorIndex)
                        : palette.primaryText)
            }
            .frame(width: diameter, height: diameter)
            .overlay { Circle().strokeBorder(palette.cardBorder, lineWidth: 1) }
            .overlay(alignment: .bottomTrailing) { selectionBadge(isSelected) }
        }
        .buttonStyle(CircularSelectionButtonStyle(diameter: diameter))
        .focusEffectDisabled()
        .accessibilityLabel(Text(symbol))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: Emoji

    private var emojiCategoriesSection: some View {
        VStack(alignment: .leading, spacing: 28) {
            ForEach(Profile.avatarEmojiCategories) { category in
                // Hide glyphs the current tvOS is too old to draw (they'd render
                // as empty boxes); skip a category that ends up empty.
                let available = category.availableEmojis(
                    osMajor: osVersion.majorVersion,
                    osMinor: osVersion.minorVersion
                ).map(\.value)
                if !available.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        categoryHeader(category.title)
                        emojiRows(for: available)
                    }
                }
            }
        }
    }

    /// Eager rows of 8 (same rationale as `symbolRows`: a lazy grid would blank
    /// tiles out as they scroll near the dialog's top edge).
    @ViewBuilder
    private func emojiRows(for emojis: [String]) -> some View {
        let perRow = 8
        let rows = stride(from: 0, to: emojis.count, by: perRow).map {
            Array(emojis[$0..<min($0 + perRow, emojis.count)])
        }
        VStack(spacing: 18) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 18) {
                    ForEach(row, id: \.self) { emoji in
                        emojiTile(emoji).frame(maxWidth: .infinity)
                    }
                    if row.count < perRow {
                        ForEach(0..<(perRow - row.count), id: \.self) { _ in
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
    }

    private func emojiTile(_ emoji: String) -> some View {
        let isSelected = emoji == avatarEmoji
        let diameter: CGFloat = 92
        return Button {
            avatarEmoji = emoji
        } label: {
            ZStack {
                // The picker keeps a calm neutral disc; the actual background
                // (neutral or a chosen colour) is set in the Colour section and
                // shown live in the preview.
                Circle().fill(palette.cardSurface)
                Text(emoji)
                    .font(.system(size: 44))
            }
            .frame(width: diameter, height: diameter)
            .overlay { Circle().strokeBorder(palette.cardBorder, lineWidth: 1) }
            .overlay(alignment: .bottomTrailing) { selectionBadge(isSelected) }
        }
        .buttonStyle(CircularSelectionButtonStyle(diameter: diameter))
        .focusEffectDisabled()
        .accessibilityLabel(Text("Emoji \(emoji)"))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
    /// selected after focus moves away.
    @ViewBuilder
    private func selectionBadge(_ isSelected: Bool) -> some View {
        if isSelected {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 34, weight: .bold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, palette.accent)
                .background(Circle().fill(.white).padding(5))
                .offset(x: 4, y: 4)
        }
    }

    // MARK: Colors

    private var colorSection: some View {
        // Fixed 8-wide grid so rows are always even (32 colours = 4 clean rows),
        // rather than an adaptive grid that leaves a ragged last row.
        let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 8)
        let emojiMode = avatarMode == .emoji
        return VStack(alignment: .leading, spacing: 16) {
            sectionHeader("Color")
            // Emoji avatars default to a neutral disc (colours often clash with a
            // multicolour emoji), so Emoji mode offers a distinct "No color"
            // option on its own line — kept out of the grid so the colour rows
            // stay even.
            if emojiMode {
                HStack(spacing: 12) {
                    neutralSwatch
                    Text("No color")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(palette.secondaryText)
                    Spacer(minLength: 0)
                }
            }
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(0..<ProfileTileColor.palette.count, id: \.self) { index in
                    colorSwatch(index, emojiMode: emojiMode)
                }
            }
        }
    }

    /// The "no colour" option for emoji avatars — a theme neutral disc that maps
    /// to `emojiColorIndex == nil`.
    private var neutralSwatch: some View {
        let isSelected = emojiColorIndex == nil
        let diameter: CGFloat = 42
        return Button {
            emojiColorIndex = nil
        } label: {
            Circle()
                .fill(Color.gray.opacity(0.35))
                .frame(width: diameter, height: diameter)
                .overlay { Circle().strokeBorder(palette.cardBorder, lineWidth: 1) }
                .overlay {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 18, weight: .heavy))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                    } else {
                        Image(systemName: "slash.circle")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(palette.secondaryText)
                    }
                }
        }
        .buttonStyle(CircularSelectionButtonStyle(diameter: diameter))
        .focusEffectDisabled()
        .accessibilityLabel(Text("Neutral background"))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func colorSwatch(_ index: Int, emojiMode: Bool) -> some View {
        // In emoji mode the colour choice writes emojiColorIndex; for symbols it
        // writes colorIndex.
        let isSelected = emojiMode ? (emojiColorIndex == index) : (index == colorIndex)
        let diameter: CGFloat = 42
        return Button {
            if emojiMode { emojiColorIndex = index } else { colorIndex = index }
        } label: {
            Circle()
                .fill(ProfileTileColor.color(forIndex: index))
                .frame(width: diameter, height: diameter)
                // Hairline so pale swatches still read against the surface.
                .overlay { Circle().strokeBorder(palette.cardBorder, lineWidth: 1) }
                // A swatch IS its content, so the selected mark sits centred on
                // it (the standard colour-picker idiom) rather than in a corner
                // like the symbol/photo tiles. Shadow keeps the white check
                // legible on the paler swatches.
                .overlay {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 18, weight: .heavy))
                            // Legible on any swatch (dark check on white/pale,
                            // white check on dark).
                            .foregroundStyle(ProfileTileColor.legibleForeground(forIndex: index))
                            .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                    }
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
                        .font(.headline)
                }
                .plozzGlassPillButton()
                .focusEffectDisabled()
                .padding(.top, 6)
            }
            .padding(.vertical, 8)
        } else {
            let columns = [GridItem(.adaptive(minimum: 150, maximum: 184), spacing: 26)]
            LazyVGrid(columns: columns, spacing: 26) {
                ForEach(photoCandidates) { candidate in
                    photoTile(candidate)
                }
            }
        }
    }

    /// A borrowable-photo tile: a round photo styled exactly like the symbol /
    /// emoji / colour tiles (the shared `CircularSelectionButtonStyle`, which
    /// owns focus and draws our single circular halo — no stray `.plain` tvOS
    /// platter behind it), with the source labelled beneath the button.
    private func photoTile(_ candidate: ProfilePhotoCandidate) -> some View {
        let isSelected = avatarImageURL == candidate.imageURL.absoluteString
        let diameter: CGFloat = 128
        return VStack(spacing: 10) {
            Button {
                avatarImageURL = candidate.imageURL.absoluteString
            } label: {
                ZStack {
                    Circle().fill(palette.cardSurface)
                    FallbackAsyncImage(urls: [candidate.imageURL], variant: .posterCard) {
                        Image(systemName: "person.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(palette.secondaryText)
                    }
                    .frame(width: diameter, height: diameter)
                    .clipShape(Circle())
                }
                .frame(width: diameter, height: diameter)
                .overlay { Circle().strokeBorder(palette.cardBorder, lineWidth: 1) }
                .overlay(alignment: .bottomTrailing) { selectionBadge(isSelected) }
            }
            .buttonStyle(CircularSelectionButtonStyle(diameter: diameter))
            .focusEffectDisabled()
            .accessibilityLabel(Text("Photo from \(candidate.detailLabel)"))
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)

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

    // MARK: Section headers

    /// L1 section label — the app's shared uppercase settings section-header
    /// style, so "Name / Avatar / Color / Delete" read as peers of the section
    /// headers everywhere else in Settings and sit clearly below the page title.
    private func sectionHeader(_ text: String) -> some View {
        Text(text).settingsSectionHeader()
    }

    /// L2 sub-group label (the symbol categories). Sentence-case and a step
    /// smaller than an L1 section header so it nests *under* "Avatar" instead of
    /// competing with it.
    private func categoryHeader(_ text: String) -> some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
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
        // `currentDraft` already carries the cosmetic values plus the preserved
        // non-cosmetic fields (membership / Plex mapping), so callers on the
        // single `saveProfile(draft)` path never wipe them.
        onSave(currentDraft)
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
#endif
