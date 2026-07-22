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
    @FocusState private var nameFieldFocused: Bool

    fileprivate enum AvatarMode: Hashable { case symbol, emoji, photo }

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

    private func symbolAccessibilityName(_ symbol: String) -> String {
        symbol
            .replacingOccurrences(of: ".fill", with: "")
            .replacingOccurrences(of: ".inverse", with: "")
            .replacingOccurrences(of: "holdinghands", with: "holding hands")
            .replacingOccurrences(of: "gamecontroller", with: "game controller")
            .replacingOccurrences(of: "soccerball", with: "soccer ball")
            .replacingOccurrences(of: "puzzlepiece", with: "puzzle piece")
            .replacingOccurrences(of: "paintpalette", with: "paint palette")
            .replacingOccurrences(of: "pawprint", with: "paw print")
            .replacingOccurrences(of: ".", with: " ")
            .localizedCapitalized
    }

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
        #if os(tvOS)
        tvOSBody
        #else
        iOSBody
        #endif
    }

    #if os(tvOS)

    private var tvOSBody: some View {
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
        // A sheet doesn't inherit the colour scheme the app pushes down at the
        // root, so semantic colours (.primary/.secondary, materials, the default
        // TextField text) would render for the *system* scheme — invisible when
        // it disagrees with the editor's own themed background. Re-assert the
        // active theme's scheme here so everything resolves correctly.
        .environment(\.colorScheme, palette.isLight ? .light : .dark)
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

    #endif

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

    #if os(tvOS)

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

    #endif

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

    #if os(tvOS)

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
                // tvOS gives a focused text field its own bright (near-white)
                // capsule + focus ring, so on focus the text must go DARK to stay
                // readable; unfocused it sits on our themed container and uses the
                // theme's primary text.
                .foregroundStyle(nameFieldFocused ? Color.black : palette.primaryText)
                .focused($nameFieldFocused)
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
                .background {
                    // A visible themed input container so the field never
                    // disappears into the page (on Pure Black's pure black a bare
                    // TextField shows nothing but the typed text). On focus we
                    // fade it out and let tvOS's own focus capsule + ring be the
                    // single focus treatment — otherwise our fill/border fights
                    // the system one (double outline, white-on-white text).
                    RoundedRectangle(cornerRadius: PlozzTheme.Metrics.Radius.control, style: .continuous)
                        .fill(palette.cardSurface)
                        .overlay {
                            RoundedRectangle(cornerRadius: PlozzTheme.Metrics.Radius.control, style: .continuous)
                                .strokeBorder(palette.cardBorder, lineWidth: 1)
                        }
                        .opacity(nameFieldFocused ? 0 : 1)
                }
                .animation(.easeOut(duration: 0.16), value: nameFieldFocused)
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
        .accessibilityLabel(Text(symbolAccessibilityName(symbol)))
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
        .accessibilityLabel(Text(ProfileTileColor.accessibilityName(forIndex: index)))
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

    /// L1 section label — uppercase, tracked, and secondary (the shared settings
    /// section-header idiom) but with an explicit theme-aware colour so it stays
    /// legible in every theme even inside a sheet (a bare `.secondary` resolves
    /// to the wrong scheme here).
    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.subheadline.weight(.bold))
            .tracking(1.8)
            .foregroundStyle(palette.secondaryText)
    }

    /// L2 sub-group label (the symbol categories). Sentence-case and a step
    /// smaller than an L1 section header so it nests *under* "Avatar" instead of
    /// competing with it. Theme-aware colour for the same sheet reason.
    private func categoryHeader(_ text: String) -> some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(palette.secondaryText)
    }

    #endif

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

#if os(iOS)

// MARK: - iOS touch layout
//
// A scrollable vertical editor that renders the SAME shared state
// (`currentDraft`, photo candidates, avatar mode) as the tvOS focus layout —
// only the presentation differs. It reuses `ProfileAvatarView` for the live
// preview and `ProfileTileColor` for the swatches, so photo / emoji / symbol /
// colour all render identically to every other avatar surface. Selection uses
// plain touch buttons (no focus engine) with a highlighted ring, native
// segmented mode control, and adaptive grids that reflow for compact vs regular
// width. Save/Create/Cancel/Delete live in the host's navigation toolbar.
extension ProfileEditorView {
    var iOSBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                IOSProfilePreviewSection(
                    profileID: editingProfile?.id ?? "preview",
                    profileName: trimmedName,
                    displayName: previewName,
                    subtitle: previewSubtitle,
                    avatarSymbol: avatarSymbol,
                    colorIndex: colorIndex,
                    avatarImageURL: effectiveImageURL,
                    avatarEmoji: effectiveEmoji,
                    avatarEmojiColorIndex: effectiveEmojiColorIndex
                )
                IOSProfileNameSection(name: $name)
                IOSProfileAvatarSection(
                    avatarMode: $avatarMode,
                    avatarSymbol: $avatarSymbol,
                    colorIndex: colorIndex,
                    avatarEmoji: $avatarEmoji,
                    avatarImageURL: $avatarImageURL,
                    photoCandidates: photoCandidates,
                    osMajorVersion: osVersion.majorVersion,
                    osMinorVersion: osVersion.minorVersion
                )
                if colorApplies {
                    IOSProfileColorSection(
                        avatarMode: avatarMode,
                        colorIndex: $colorIndex,
                        emojiColorIndex: $emojiColorIndex
                    )
                }
                if isEditing, canDelete, onDelete != nil {
                    IOSProfileDeleteSection(showConfirmation: $showDeleteConfirmation)
                }
            }
            .padding(20)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background { AppBackground(palette: palette).ignoresSafeArea() }
        .scrollContentBackground(.hidden)
        .environment(\.colorScheme, palette.isLight ? .light : .dark)
        .navigationTitle(isEditing ? "Edit Profile" : "New Profile")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadPhotoCandidates() }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: attemptCancel)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(isEditing ? "Save" : "Create", action: save)
                    .disabled(!canSave)
            }
        }
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
}

fileprivate struct IOSProfilePreviewSection: View {
    let profileID: String
    let profileName: String
    let displayName: String
    let subtitle: String
    let avatarSymbol: String
    let colorIndex: Int
    let avatarImageURL: String?
    let avatarEmoji: String?
    let avatarEmojiColorIndex: Int?

    @Environment(\.themePalette) private var palette

    var body: some View {
        let profile = Profile(
            id: profileID,
            name: profileName,
            avatarSymbol: avatarSymbol,
            colorIndex: colorIndex,
            avatarImageURL: avatarImageURL,
            avatarEmoji: avatarEmoji,
            avatarEmojiColorIndex: avatarEmojiColorIndex
        )
        VStack(spacing: 12) {
            ProfileAvatarView(profile: profile, size: 104)
                .shadow(color: .black.opacity(0.2), radius: 12, y: 5)
            Text(displayName)
                .font(.title2.weight(.bold))
                .foregroundStyle(palette.primaryText)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(palette.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Preview: \(displayName), \(subtitle)"))
    }
}

fileprivate struct IOSProfileNameSection: View {
    @Binding var name: String

    @Environment(\.themePalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            IOSProfileSectionHeader(text: "Name")
            TextField("Profile name", text: $name)
                .textContentType(.name)
                .autocorrectionDisabled()
                .font(.title3)
                .foregroundStyle(palette.primaryText)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(minHeight: 44)
                .background {
                    RoundedRectangle(cornerRadius: PlozzTheme.Metrics.Radius.control, style: .continuous)
                        .fill(palette.cardSurface)
                        .overlay {
                            RoundedRectangle(cornerRadius: PlozzTheme.Metrics.Radius.control, style: .continuous)
                                .strokeBorder(palette.cardBorder, lineWidth: 1)
                        }
                }
                .accessibilityLabel(Text("Profile name"))
        }
    }
}

fileprivate struct IOSProfileAvatarSection: View {
    @Binding var avatarMode: ProfileEditorView.AvatarMode
    @Binding var avatarSymbol: String
    let colorIndex: Int
    @Binding var avatarEmoji: String?
    @Binding var avatarImageURL: String?
    let photoCandidates: [ProfilePhotoCandidate]
    let osMajorVersion: Int
    let osMinorVersion: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            IOSProfileSectionHeader(text: "Avatar")
            IOSProfileAvatarModePicker(avatarMode: $avatarMode)
            IOSProfileAvatarPicker(
                avatarMode: avatarMode,
                avatarSymbol: $avatarSymbol,
                colorIndex: colorIndex,
                avatarEmoji: $avatarEmoji,
                avatarImageURL: $avatarImageURL,
                photoCandidates: photoCandidates,
                osMajorVersion: osMajorVersion,
                osMinorVersion: osMinorVersion
            )
        }
    }
}

fileprivate struct IOSProfileAvatarModePicker: View {
    @Binding var avatarMode: ProfileEditorView.AvatarMode

    var body: some View {
        Picker("Avatar style", selection: $avatarMode) {
            Text("Emoji").tag(ProfileEditorView.AvatarMode.emoji)
            Text("Photo").tag(ProfileEditorView.AvatarMode.photo)
            Text("Symbol").tag(ProfileEditorView.AvatarMode.symbol)
        }
        .pickerStyle(.segmented)
    }
}

fileprivate struct IOSProfileAvatarPicker: View {
    let avatarMode: ProfileEditorView.AvatarMode
    @Binding var avatarSymbol: String
    let colorIndex: Int
    @Binding var avatarEmoji: String?
    @Binding var avatarImageURL: String?
    let photoCandidates: [ProfilePhotoCandidate]
    let osMajorVersion: Int
    let osMinorVersion: Int

    @State private var showingFullPicker = false
    @State private var rowWidth: CGFloat = 0

    // The compact row fills the available width: it shows the leading "browse
    // all" opener plus as many suggestions as fit one row (fewer on a narrow
    // iPhone, more on an iPad-width sheet), with the full set behind the opener.
    // Apple's avatar-picker pattern (a few options + a first cell that drills
    // into everything), sized to the container rather than a fixed count.
    private static let cellDiameter: CGFloat = 60
    private static let cellSpacing: CGFloat = 12

    /// How many cells (including the opener) fill the measured row width.
    private var fitCount: Int {
        iOSProfileFitCount(
            width: rowWidth,
            cell: Self.cellDiameter,
            spacing: Self.cellSpacing
        )
    }

    var body: some View {
        Group {
            switch avatarMode {
            case .symbol: symbolRow
            case .emoji: emojiRow
            case .photo: photoRow
            }
        }
        .sheet(isPresented: $showingFullPicker) { fullPickerSheet }
    }

    private var symbolRow: some View {
        HStack(spacing: Self.cellSpacing) {
            IOSProfileMoreCell(systemImage: "square.grid.2x2", label: "Browse all symbols") {
                showingFullPicker = true
            }
            ForEach(fewSymbols, id: \.self) { symbol in
                IOSProfileSymbolTile(
                    symbol: symbol,
                    avatarSymbol: $avatarSymbol,
                    colorIndex: colorIndex
                )
            }
        }
        .iOSProfileMeasureWidth($rowWidth)
    }

    private var emojiRow: some View {
        HStack(spacing: Self.cellSpacing) {
            IOSProfileMoreCell(systemImage: "face.smiling", label: "Browse all emoji") {
                showingFullPicker = true
            }
            ForEach(fewEmoji, id: \.self) { emoji in
                IOSProfileEmojiTile(emoji: emoji, avatarEmoji: $avatarEmoji)
            }
        }
        .iOSProfileMeasureWidth($rowWidth)
    }

    @ViewBuilder
    private var photoRow: some View {
        if photoCandidates.isEmpty {
            // Reuse the picker's empty-state hint (no "browse all" to open).
            IOSProfilePhotoPicker(photoCandidates: [], avatarImageURL: $avatarImageURL)
        } else {
            HStack(spacing: Self.cellSpacing) {
                IOSProfileMoreCell(systemImage: "photo.on.rectangle", label: "Browse all photos") {
                    showingFullPicker = true
                }
                ForEach(fewPhotos) { candidate in
                    IOSProfileCompactPhotoTile(candidate: candidate, avatarImageURL: $avatarImageURL)
                }
            }
            .iOSProfileMeasureWidth($rowWidth)
        }
    }

    private var fullPickerSheet: some View {
        IOSProfilePickerSheet(title: sheetTitle) {
            switch avatarMode {
            case .symbol:
                IOSProfileSymbolPicker(avatarSymbol: $avatarSymbol, colorIndex: colorIndex)
            case .emoji:
                IOSProfileEmojiPicker(
                    avatarEmoji: $avatarEmoji,
                    osMajorVersion: osMajorVersion,
                    osMinorVersion: osMinorVersion
                )
            case .photo:
                IOSProfilePhotoPicker(photoCandidates: photoCandidates, avatarImageURL: $avatarImageURL)
            }
        }
        // Picking any item is a single choice, so close the sheet and return the
        // user to the updated compact row + live preview.
        .onChange(of: avatarSymbol) { _, _ in showingFullPicker = false }
        .onChange(of: avatarEmoji) { _, _ in showingFullPicker = false }
        .onChange(of: avatarImageURL) { _, _ in showingFullPicker = false }
    }

    private var sheetTitle: String {
        switch avatarMode {
        case .symbol: return "Symbols"
        case .emoji: return "Emoji"
        case .photo: return "Photos"
        }
    }

    private var fewSymbols: [String] {
        iOSProfileFew(current: avatarSymbol, from: Profile.defaultAvatarSymbols, count: fitCount - 1)
    }

    private var fewEmoji: [String] {
        let all = Profile.avatarEmojiCategories
            .flatMap { $0.availableEmojis(osMajor: osMajorVersion, osMinor: osMinorVersion) }
            .map(\.value)
        return iOSProfileFew(current: avatarEmoji, from: all, count: fitCount - 1)
    }

    private var fewPhotos: [ProfilePhotoCandidate] {
        var ordered: [ProfilePhotoCandidate] = []
        if let url = avatarImageURL,
           let match = photoCandidates.first(where: { $0.imageURL.absoluteString == url }) {
            ordered.append(match)
        }
        for candidate in photoCandidates where !ordered.contains(where: { $0.id == candidate.id }) {
            ordered.append(candidate)
        }
        return Array(ordered.prefix(max(fitCount - 1, 1)))
    }
}

fileprivate struct IOSProfileSymbolPicker: View {
    @Binding var avatarSymbol: String
    let colorIndex: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(Profile.avatarSymbolCategories) { category in
                VStack(alignment: .leading, spacing: 10) {
                    IOSProfileCategoryHeader(text: category.title)
                    IOSProfileCategoryGrid(items: category.symbols) { symbol in
                        IOSProfileSymbolTile(
                            symbol: symbol,
                            avatarSymbol: $avatarSymbol,
                            colorIndex: colorIndex
                        )
                    }
                }
            }
        }
    }
}

fileprivate struct IOSProfileSymbolTile: View {
    let symbol: String
    @Binding var avatarSymbol: String
    let colorIndex: Int

    @Environment(\.themePalette) private var palette

    var body: some View {
        let isSelected = symbol == avatarSymbol
        let diameter: CGFloat = 60
        Button {
            avatarSymbol = symbol
        } label: {
            ZStack {
                Circle().fill(isSelected
                    ? AnyShapeStyle(ProfileTileColor.color(forIndex: colorIndex))
                    : AnyShapeStyle(palette.cardSurface))
                Image(systemName: symbol)
                    .font(.system(size: 27, weight: .semibold))
                    .foregroundStyle(isSelected
                        ? ProfileTileColor.legibleForeground(forIndex: colorIndex)
                        : palette.primaryText)
            }
            .frame(width: diameter, height: diameter)
            .overlay(IOSProfileSelectionRing(isSelected: isSelected))
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(iOSProfileSymbolAccessibilityName(symbol)))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

fileprivate struct IOSProfileEmojiPicker: View {
    @Binding var avatarEmoji: String?
    let osMajorVersion: Int
    let osMinorVersion: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(Profile.avatarEmojiCategories) { category in
                let available = category.availableEmojis(
                    osMajor: osMajorVersion,
                    osMinor: osMinorVersion
                ).map(\.value)
                if !available.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        IOSProfileCategoryHeader(text: category.title)
                        IOSProfileCategoryGrid(items: available) { emoji in
                            IOSProfileEmojiTile(emoji: emoji, avatarEmoji: $avatarEmoji)
                        }
                    }
                }
            }
        }
    }
}

fileprivate struct IOSProfileEmojiTile: View {
    let emoji: String
    @Binding var avatarEmoji: String?

    @Environment(\.themePalette) private var palette

    var body: some View {
        let isSelected = emoji == avatarEmoji
        let diameter: CGFloat = 60
        Button {
            avatarEmoji = emoji
        } label: {
            ZStack {
                Circle().fill(palette.cardSurface)
                Text(emoji).font(.system(size: 30))
            }
            .frame(width: diameter, height: diameter)
            .overlay(IOSProfileSelectionRing(isSelected: isSelected))
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Emoji \(emoji)"))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

fileprivate struct IOSProfilePhotoPicker: View {
    let photoCandidates: [ProfilePhotoCandidate]
    @Binding var avatarImageURL: String?

    @Environment(\.themePalette) private var palette

    @ViewBuilder
    var body: some View {
        if photoCandidates.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Label("No photos to borrow yet", systemImage: "photo.on.rectangle")
                    .font(.headline)
                    .foregroundStyle(palette.primaryText)
                Text("Sign in to a Plex Home user or Jellyfin user that has a profile photo, then come back to use it here. In the meantime, an emoji or symbol works great.")
                    .font(.subheadline)
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 8)
        } else {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 96, maximum: 132), spacing: 18)],
                spacing: 18
            ) {
                ForEach(photoCandidates) { candidate in
                    IOSProfilePhotoTile(
                        candidate: candidate,
                        avatarImageURL: $avatarImageURL
                    )
                }
            }
        }
    }
}

fileprivate struct IOSProfilePhotoTile: View {
    let candidate: ProfilePhotoCandidate
    @Binding var avatarImageURL: String?

    @Environment(\.themePalette) private var palette

    var body: some View {
        let isSelected = avatarImageURL == candidate.imageURL.absoluteString
        let diameter: CGFloat = 88
        VStack(spacing: 8) {
            Button {
                avatarImageURL = candidate.imageURL.absoluteString
            } label: {
                ZStack {
                    Circle().fill(palette.cardSurface)
                    FallbackAsyncImage(urls: [candidate.imageURL], variant: .musicThumbnail) {
                        Image(systemName: "person.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(palette.secondaryText)
                    }
                    .frame(width: diameter, height: diameter)
                    .clipShape(Circle())
                }
                .frame(width: diameter, height: diameter)
                .overlay(IOSProfileSelectionRing(isSelected: isSelected))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Photo from \(candidate.detailLabel)"))
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)

            VStack(spacing: 1) {
                Text(candidate.providerLabel)
                    .font(.caption2.weight(.semibold))
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

fileprivate struct IOSProfileColorSection: View {
    let avatarMode: ProfileEditorView.AvatarMode
    @Binding var colorIndex: Int
    @Binding var emojiColorIndex: Int?

    @State private var showingAllColors = false
    @State private var rowWidth: CGFloat = 0

    // Swatches are a touch smaller than avatar tiles; fit as many as the row
    // width allows.
    private static let cellDiameter: CGFloat = 52
    private static let cellSpacing: CGFloat = 12

    private let columns = [GridItem(.adaptive(minimum: 44, maximum: 56), spacing: 12)]

    private var fitCount: Int {
        iOSProfileFitCount(
            width: rowWidth,
            cell: Self.cellDiameter,
            spacing: Self.cellSpacing
        )
    }

    var body: some View {
        let emojiMode = avatarMode == .emoji
        VStack(alignment: .leading, spacing: 12) {
            IOSProfileSectionHeader(text: "Color")
            // A few swatches inline (current first) + a "More colors" opener to
            // the full palette, filling the row width like the avatar rows so
            // colour is reachable without a long scroll.
            HStack(spacing: Self.cellSpacing) {
                IOSProfileMoreCell(systemImage: "paintpalette", label: "More colors") {
                    showingAllColors = true
                }
                if emojiMode {
                    IOSProfileNeutralSwatch(emojiColorIndex: $emojiColorIndex)
                }
                ForEach(fewColorIndices(emojiMode: emojiMode), id: \.self) { index in
                    IOSProfileColorSwatch(
                        index: index,
                        emojiMode: emojiMode,
                        colorIndex: $colorIndex,
                        emojiColorIndex: $emojiColorIndex
                    )
                }
            }
            .iOSProfileMeasureWidth($rowWidth)
        }
        .sheet(isPresented: $showingAllColors) {
            IOSProfilePickerSheet(title: "Color") {
                LazyVGrid(columns: columns, spacing: 12) {
                    if emojiMode {
                        IOSProfileNeutralSwatch(emojiColorIndex: $emojiColorIndex)
                    }
                    ForEach(0..<ProfileTileColor.palette.count, id: \.self) { index in
                        IOSProfileColorSwatch(
                            index: index,
                            emojiMode: emojiMode,
                            colorIndex: $colorIndex,
                            emojiColorIndex: $emojiColorIndex
                        )
                    }
                }
            }
            .onChange(of: colorIndex) { _, _ in showingAllColors = false }
            .onChange(of: emojiColorIndex) { _, _ in showingAllColors = false }
        }
    }

    private func fewColorIndices(emojiMode: Bool) -> [Int] {
        let current = emojiMode ? emojiColorIndex : colorIndex
        // The opener always takes one slot; emoji mode also spends one on the
        // neutral swatch, so it shows one fewer palette colour.
        let count = fitCount - (emojiMode ? 2 : 1)
        return iOSProfileFew(
            current: current,
            from: Array(0..<ProfileTileColor.palette.count),
            count: max(count, 1)
        )
    }
}

fileprivate struct IOSProfileNeutralSwatch: View {
    @Binding var emojiColorIndex: Int?

    @Environment(\.themePalette) private var palette

    var body: some View {
        let isSelected = emojiColorIndex == nil
        let diameter: CGFloat = 44
        Button {
            emojiColorIndex = nil
        } label: {
            Circle()
                .fill(Color.gray.opacity(0.35))
                .frame(width: diameter, height: diameter)
                .overlay {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 17, weight: .heavy))
                            .foregroundStyle(.white)
                    } else {
                        Image(systemName: "slash.circle")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(palette.secondaryText)
                    }
                }
                .overlay(IOSProfileSwatchRing(isSelected: isSelected))
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Neutral background"))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

fileprivate struct IOSProfileColorSwatch: View {
    let index: Int
    let emojiMode: Bool
    @Binding var colorIndex: Int
    @Binding var emojiColorIndex: Int?

    var body: some View {
        let isSelected = emojiMode ? (emojiColorIndex == index) : (index == colorIndex)
        let diameter: CGFloat = 44
        Button {
            if emojiMode { emojiColorIndex = index } else { colorIndex = index }
        } label: {
            Circle()
                .fill(ProfileTileColor.color(forIndex: index))
                .frame(width: diameter, height: diameter)
                .overlay {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 17, weight: .heavy))
                            .foregroundStyle(ProfileTileColor.legibleForeground(forIndex: index))
                    }
                }
                .overlay(IOSProfileSwatchRing(isSelected: isSelected))
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(ProfileTileColor.accessibilityName(forIndex: index)))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The leading "custom / browse all" cell in a compact avatar or colour row.
/// Mirrors Apple's pattern where the first cell opens a second-level picker with
/// the full set, keeping the inline row short and the whole editor scannable.
fileprivate struct IOSProfileMoreCell: View {
    let systemImage: String
    let label: String
    let action: () -> Void

    @Environment(\.themePalette) private var palette

    var body: some View {
        let diameter: CGFloat = 60
        Button(action: action) {
            ZStack {
                Circle().fill(palette.accent.opacity(0.18))
                Image(systemName: systemImage)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(palette.accent)
            }
            .frame(width: diameter, height: diameter)
            .overlay {
                Circle().strokeBorder(
                    palette.accent.opacity(0.55),
                    style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
                )
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }
}

/// A label-less circular photo cell for the compact row. The full photo picker
/// (with provider labels) lives in the "browse all" sheet.
fileprivate struct IOSProfileCompactPhotoTile: View {
    let candidate: ProfilePhotoCandidate
    @Binding var avatarImageURL: String?

    @Environment(\.themePalette) private var palette

    var body: some View {
        let isSelected = avatarImageURL == candidate.imageURL.absoluteString
        let diameter: CGFloat = 60
        Button {
            avatarImageURL = candidate.imageURL.absoluteString
        } label: {
            ZStack {
                Circle().fill(palette.cardSurface)
                FallbackAsyncImage(urls: [candidate.imageURL], variant: .musicThumbnail) {
                    Image(systemName: "person.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(palette.secondaryText)
                }
                .frame(width: diameter, height: diameter)
                .clipShape(Circle())
            }
            .frame(width: diameter, height: diameter)
            .overlay(IOSProfileSelectionRing(isSelected: isSelected))
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Photo from \(candidate.detailLabel)"))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A second-level modal that hosts a full picker grid with a Done button, themed
/// to match the editor. Opened by an ``IOSProfileMoreCell``.
fileprivate struct IOSProfilePickerSheet<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    @Environment(\.dismiss) private var dismiss
    @Environment(\.themePalette) private var palette

    var body: some View {
        NavigationStack {
            ScrollView {
                content
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background { AppBackground(palette: palette).ignoresSafeArea() }
            .scrollContentBackground(.hidden)
            .environment(\.colorScheme, palette.isLight ? .light : .dark)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// Puts the current selection first, then fills from `list` (de-duplicated),
/// capped at `count` — so a compact row always shows the active choice plus a
/// few defaults, and the rest live behind the "browse all" opener.
fileprivate func iOSProfileFew<T: Hashable>(current: T?, from list: [T], count: Int) -> [T] {
    guard count > 0 else { return [] }
    var ordered: [T] = []
    if let current { ordered.append(current) }
    for item in list where !ordered.contains(item) {
        ordered.append(item)
    }
    return Array(ordered.prefix(count))
}

/// How many cells of `cell` diameter (plus `spacing`) fit in `width`, so a
/// compact row fills the available width — fewer on a narrow iPhone, more on an
/// iPad-width sheet. Clamped so it degrades sanely before the width is measured
/// and never grows unreasonably wide.
fileprivate func iOSProfileFitCount(
    width: CGFloat,
    cell: CGFloat,
    spacing: CGFloat,
    fallback: Int = 5,
    maxCount: Int = 12
) -> Int {
    guard width > 0 else { return fallback }
    let n = Int((width + spacing) / (cell + spacing))
    return min(maxCount, max(3, n))
}

/// A category grid for the full-picker sheets that distributes each row **edge
/// to edge**: the first tile sits flush-left, the last flush-right, with equal
/// gaps between (a "space-between" layout) so the row fills the sheet width
/// instead of clustering on the left with dead space on the right. The column
/// count is the largest **divisor of 8** (8 / 4 / 2) that fits the measured
/// width, so — because every avatar category holds exactly 8 items — each row is
/// full and no orphan tile is stranded on a new row.
fileprivate struct IOSProfileCategoryGrid<Item: Hashable, Cell: View>: View {
    let items: [Item]
    @ViewBuilder let cell: (Item) -> Cell

    @State private var width: CGFloat = 0

    private let cellSize: CGFloat = 60
    private let minGap: CGFloat = 14
    private let rowSpacing: CGFloat = 16

    var body: some View {
        let count = columnCount(for: width)
        let rows = stride(from: 0, to: items.count, by: count).map { start in
            Array(items[start..<min(start + count, items.count)])
        }
        VStack(spacing: rowSpacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                row.count == count ? AnyView(fullRow(row)) : AnyView(partialRow(row))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .iOSProfileMeasureWidth($width)
    }

    /// A full row: equal spacers push the tiles edge to edge.
    private func fullRow(_ row: [Item]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(row.enumerated()), id: \.offset) { index, item in
                if index > 0 { Spacer(minLength: minGap) }
                cell(item).frame(width: cellSize)
            }
        }
    }

    /// A short final row (shouldn't occur for the 8-item categories, but handled
    /// so a filtered/odd count stays tidy): fixed gaps, left-aligned.
    private func partialRow(_ row: [Item]) -> some View {
        HStack(spacing: minGap) {
            ForEach(Array(row.enumerated()), id: \.offset) { _, item in
                cell(item).frame(width: cellSize)
            }
            Spacer(minLength: 0)
        }
    }

    private func columnCount(for width: CGFloat) -> Int {
        guard width > 0 else { return 4 }
        let fit = max(1, Int((width + minGap) / (cellSize + minGap)))
        for divisor in [8, 4, 2] where divisor <= fit { return divisor }
        return 1
    }
}

fileprivate extension View {
    /// Writes this view's laid-out width into `width`. Because the compact rows
    /// use width-flexible cells, the row width is driven by the parent (not the
    /// child count), so feeding it back to compute the count can't loop.
    func iOSProfileMeasureWidth(_ width: Binding<CGFloat>) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { width.wrappedValue = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, newValue in
                        width.wrappedValue = newValue
                    }
            }
        }
    }
}

fileprivate struct IOSProfileDeleteSection: View {
    @Binding var showConfirmation: Bool

    var body: some View {
        Button(role: .destructive) {
            showConfirmation = true
        } label: {
            Label("Delete Profile", systemImage: "trash")
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .tint(.red)
        .padding(.top, 8)
    }
}

fileprivate struct IOSProfileSelectionRing: View {
    let isSelected: Bool

    @Environment(\.themePalette) private var palette

    var body: some View {
        Circle().strokeBorder(
            isSelected ? palette.accent : palette.cardBorder,
            lineWidth: isSelected ? 3 : 1
        )
    }
}

fileprivate struct IOSProfileSwatchRing: View {
    let isSelected: Bool

    @Environment(\.themePalette) private var palette

    var body: some View {
        Circle().strokeBorder(
            isSelected ? palette.accent : palette.cardBorder,
            lineWidth: isSelected ? 3 : 1
        )
    }
}

fileprivate struct IOSProfileSectionHeader: View {
    let text: String

    @Environment(\.themePalette) private var palette

    var body: some View {
        Text(text.uppercased())
            .font(.subheadline.weight(.bold))
            .tracking(1.4)
            .foregroundStyle(palette.secondaryText)
    }
}

fileprivate struct IOSProfileCategoryHeader: View {
    let text: String

    @Environment(\.themePalette) private var palette

    var body: some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(palette.secondaryText)
    }
}

fileprivate func iOSProfileSymbolAccessibilityName(_ symbol: String) -> String {
    symbol
        .replacingOccurrences(of: ".fill", with: "")
        .replacingOccurrences(of: ".inverse", with: "")
        .replacingOccurrences(of: "holdinghands", with: "holding hands")
        .replacingOccurrences(of: "gamecontroller", with: "game controller")
        .replacingOccurrences(of: "soccerball", with: "soccer ball")
        .replacingOccurrences(of: "puzzlepiece", with: "puzzle piece")
        .replacingOccurrences(of: "paintpalette", with: "paint palette")
        .replacingOccurrences(of: "pawprint", with: "paw print")
        .replacingOccurrences(of: ".", with: " ")
        .localizedCapitalized
}

#endif

#if os(tvOS)

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
#endif
