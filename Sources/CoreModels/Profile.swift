import Foundation

/// A household **profile** (e.g. "Mom", "Dad", "Sister").
///
/// Profiles layer *on top of* the multi-account core: one iCloud/device
/// household can hold several profiles, each scoping the per-user state —
/// which accounts/libraries it uses, its theme, spoiler/caption/diagnostics
/// settings, and Home customization.
///
/// A `Profile` is **non-secret** metadata persisted to `UserDefaults` (see
/// `ProfileStore`). It never holds tokens: the shared account pool and its
/// Keychain tokens stay household-global in `AccountStore`; a profile merely
/// *selects a subset* of those accounts as its active set (stored alongside the
/// profile, see `ProfilePersisting.activeAccountIDs(forProfile:)`).
///
/// `id` doubles as the per-profile `UserDefaults` key namespace used to scope
/// the settings stores. The first/default profile intentionally uses a `nil`
/// namespace so an upgrading install keeps its existing settings seamlessly
/// (see `ProfileStore.migrateLegacyIfNeeded()`); additional profiles use their
/// `id`.
public struct Profile: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// SF Symbol name shown on the picker tile (no photo upload needed on tvOS).
    public var avatarSymbol: String
    /// Index into `Profile.tileColors` for the tile's accent color.
    public var colorIndex: Int
    /// When the profile was created — used for stable ordering.
    public var createdAt: Date
    /// Optional `Account.id` this profile is *backed by* (e.g. a signed-in Plex
    /// or Jellyfin account). Seeds the name/avatar and narrows the active set;
    /// `nil` for a plain app-owned profile.
    public var linkedAccountID: String?
    /// When this profile maps to a **Plex Home** user ("Who's watching?"), the
    /// Home user's `uuid`. Activating the profile switches the Plex identity for
    /// `plexHomeUserAccountID` to this user. `nil` = not mapped to a Plex user.
    public var plexHomeUserID: String?
    /// Display name of the linked Plex Home user (cached so the picker/editor can
    /// label it without a network fetch).
    public var plexHomeUserName: String?
    /// The `Account.id` of the Plex account whose Home this user belongs to. The
    /// account's stored (admin) token authorizes the switch.
    public var plexHomeUserAccountID: String?
    /// Whether switching to the linked Plex Home user needs a PIN. Cached from
    /// the Home-users list so Plozz knows to prompt without refetching. The PIN
    /// itself is never stored.
    public var plexHomeUserRequiresPIN: Bool?
    /// Cached Plex `thumb` URL for the linked Home user, so Settings can show
    /// the Plex avatar inline without re-hitting the network on every render.
    public var plexHomeUserAvatarURL: String?

    /// Per–Plex-account Home-user mappings. Keyed by the Plex `Account.id`,
    /// so a profile with TWO distinct Plex sign-ins can have a different
    /// Home user on each.
    ///
    /// Optional + lazily migrated: pre-existing profiles encoded before this
    /// field existed will decode with `nil` here, and the
    /// `homeUserBinding(forPlexAccount:)` helper falls back to the legacy
    /// single-mapping fields above. When a new selection is written we update
    /// this dict (authoritative) AND mirror the just-written entry to the
    /// legacy fields so older readers stay coherent.
    public var plexHomeUserBindings: [String: PlexHomeUserBinding]?

    /// Optional real photo for the profile (opt-in). When non-nil the picker
    /// tile and Settings hero render this image (a Plex Home-user avatar or
    /// a Jellyfin user avatar that the household has "borrowed"); when nil
    /// the profile falls back to `avatarSymbol` + `colorIndex` as before.
    ///
    /// Purely cosmetic identity — has no effect on which Plex Home user is
    /// played as (see `plexHomeUserBindings`). Decoded with `decodeIfPresent`
    /// so older profile JSON without this field migrates to `nil` cleanly.
    public var avatarImageURL: String?

    /// The **Seerr** (Overseerr / Jellyseerr) user this profile requests as.
    /// When set, requests made while this profile is active run under that
    /// Seerr user (`X-API-User`) on the shared household admin connection — so
    /// each household member gets their own request quota, approval flow,
    /// notifications, and default quality profile. `nil` = requests run as the
    /// admin ("Admin — unrestricted").
    ///
    /// This is **non-secret** (an integer id + cached display fields), exactly
    /// like the Plex Home-user mapping above; the admin API key never lives on
    /// a `Profile`. Independent of `plexHomeUserID`/`linkedAccountID`: a Seerr
    /// user is a separate identity from Plex/Jellyfin playback.
    public var seerrUserID: Int?
    /// Cached Seerr display name, so Settings can label the mapping without a
    /// network fetch. May go stale if the user is renamed/deleted in Seerr;
    /// the settings screen refreshes and re-validates on open.
    public var seerrUserName: String?
    /// Cached Seerr avatar URL for inline display in Settings.
    public var seerrUserAvatarURL: String?

    public init(
        id: String = UUID().uuidString,
        name: String,
        avatarSymbol: String = Profile.defaultAvatarSymbols[0],
        colorIndex: Int = 0,
        createdAt: Date = Date(),
        linkedAccountID: String? = nil,
        plexHomeUserID: String? = nil,
        plexHomeUserName: String? = nil,
        plexHomeUserAccountID: String? = nil,
        plexHomeUserRequiresPIN: Bool? = nil,
        plexHomeUserAvatarURL: String? = nil,
        plexHomeUserBindings: [String: PlexHomeUserBinding]? = nil,
        avatarImageURL: String? = nil,
        seerrUserID: Int? = nil,
        seerrUserName: String? = nil,
        seerrUserAvatarURL: String? = nil
    ) {
        self.id = id
        self.name = name
        self.avatarSymbol = avatarSymbol
        self.colorIndex = colorIndex
        self.createdAt = createdAt
        self.linkedAccountID = linkedAccountID
        self.plexHomeUserID = plexHomeUserID
        self.plexHomeUserName = plexHomeUserName
        self.plexHomeUserAccountID = plexHomeUserAccountID
        self.plexHomeUserRequiresPIN = plexHomeUserRequiresPIN
        self.plexHomeUserAvatarURL = plexHomeUserAvatarURL
        self.plexHomeUserBindings = plexHomeUserBindings
        self.avatarImageURL = avatarImageURL
        self.seerrUserID = seerrUserID
        self.seerrUserName = seerrUserName
        self.seerrUserAvatarURL = seerrUserAvatarURL
    }

    /// Stable namespace used to scope this profile's settings stores. The
    /// default/primary profile (`isDefault`) returns `nil` so it reads the
    /// legacy un-suffixed keys; every other profile namespaces by `id`.
    public func settingsNamespace(isDefault: Bool) -> String? {
        isDefault ? nil : id
    }
}

/// A named group of avatar SF Symbols shown as one labelled section in the
/// profile editor's symbol picker, so the (deliberately large) set stays
/// browsable — "find a fun one for a kid / a nerd / grandma" — instead of an
/// undifferentiated wall of glyphs.
public struct AvatarSymbolCategory: Hashable, Sendable, Identifiable {
    public var id: String { title }
    public let title: String
    public let symbols: [String]

    public init(title: String, symbols: [String]) {
        self.title = title
        self.symbols = symbols
    }
}

extension Profile {
    /// Curated, tvOS-friendly SF Symbols offered as profile avatars, grouped so
    /// the picker can present browsable sections. **Every symbol here is verified
    /// available on tvOS 17.0 (SF Symbols 5.0)** against the SDK's
    /// `name_availability.plist` — a blank tile means a bad name, so don't add a
    /// symbol without confirming its tvOS 17.0 availability. The very first symbol
    /// of the first category is the app-wide default avatar
    /// (`defaultAvatarSymbols[0]`), so keep `person.crop.circle.fill` leading —
    /// several call sites rely on it. Each category holds exactly 8 symbols so it
    /// renders as one clean row in the editor.
    public static let avatarSymbolCategories: [AvatarSymbolCategory] = [
        AvatarSymbolCategory(title: "People", symbols: [
            "person.crop.circle.fill",
            "person.fill",
            "person.2.fill",
            "figure.walk",
            "figure.and.child.holdinghands",
            "graduationcap.fill",
            "eyeglasses",
            "mustache.fill"
        ]),
        AvatarSymbolCategory(title: "Faces & Fun", symbols: [
            "face.smiling.inverse",
            "sunglasses.fill",
            "heart.fill",
            "crown.fill",
            "sparkles",
            "party.popper.fill",
            "flame.fill",
            "wand.and.stars"
        ]),
        AvatarSymbolCategory(title: "Sports & Fitness", symbols: [
            "figure.run",
            "figure.basketball",
            "figure.american.football",
            "figure.boxing",
            "figure.golf",
            "dumbbell.fill",
            "soccerball",
            "trophy.fill"
        ]),
        AvatarSymbolCategory(title: "Gaming & Tech", symbols: [
            "gamecontroller.fill",
            "dpad.fill",
            "die.face.6",
            "puzzlepiece.fill",
            "keyboard.fill",
            "cpu",
            "desktopcomputer",
            "visionpro"
        ]),
        AvatarSymbolCategory(title: "Music & Audio", symbols: [
            "music.note",
            "music.mic",
            "guitars.fill",
            "headphones",
            "waveform",
            "radio.fill",
            "speaker.wave.3.fill",
            "tuningfork"
        ]),
        AvatarSymbolCategory(title: "Movies & TV", symbols: [
            "film.fill",
            "tv.fill",
            "ticket.fill",
            "theatermasks.fill",
            "play.rectangle.fill",
            "rectangle.stack.fill",
            "star.fill",
            "camera.fill"
        ]),
        AvatarSymbolCategory(title: "Food & Drink", symbols: [
            "fork.knife",
            "birthday.cake.fill",
            "wineglass.fill",
            "mug.fill",
            "cup.and.saucer.fill",
            "carrot.fill",
            "takeoutbag.and.cup.and.straw.fill",
            "popcorn.fill"
        ]),
        AvatarSymbolCategory(title: "Animals", symbols: [
            "pawprint.fill",
            "dog.fill",
            "cat.fill",
            "bird.fill",
            "fish.fill",
            "hare.fill",
            "tortoise.fill",
            "lizard.fill"
        ]),
        AvatarSymbolCategory(title: "Nature & Weather", symbols: [
            "leaf.fill",
            "tree.fill",
            "mountain.2.fill",
            "tent.fill",
            "cloud.sun.fill",
            "cloud.bolt.fill",
            "snowflake",
            "rainbow"
        ]),
        AvatarSymbolCategory(title: "Space & Science", symbols: [
            "moon.stars.fill",
            "sun.max.fill",
            "atom",
            "brain.head.profile",
            "bolt.fill",
            "laser.burst",
            "antenna.radiowaves.left.and.right",
            "globe.americas.fill"
        ]),
        AvatarSymbolCategory(title: "Travel & Hobbies", symbols: [
            "airplane",
            "car.fill",
            "bicycle",
            "tram.fill",
            "map.fill",
            "binoculars.fill",
            "paintpalette.fill",
            "book.fill"
        ])
    ]

    /// Flattened superset of every offered avatar symbol, in category order.
    /// `[0]` remains `person.crop.circle.fill` — the default avatar used when
    /// none is chosen (see the `init` defaults and `ProfileStore.add`).
    public static let defaultAvatarSymbols: [String] =
        avatarSymbolCategories.flatMap(\.symbols)

    /// Palette indices for `colorIndex`. Resolved to concrete colors in the UI
    /// layer so `CoreModels` stays Foundation-only.
    public static let tileColorCount = 8

    /// A clamped, valid color index for `colorIndex`.
    public var clampedColorIndex: Int {
        guard Profile.tileColorCount > 0 else { return 0 }
        return ((colorIndex % Profile.tileColorCount) + Profile.tileColorCount) % Profile.tileColorCount
    }

    /// Picks a sensible default `colorIndex` for a **new** profile so freshly
    /// created people don't all end up the same colour (the editor otherwise
    /// always pre-selected index 0 / blue). Returns the lowest palette index not
    /// already in use; once every colour is taken it rotates by how many
    /// profiles exist so growth stays evenly spread rather than clumping on 0.
    ///
    /// Pure + Foundation-only so it's unit-testable and usable anywhere a new
    /// profile is minted, not just the editor.
    public static func suggestedColorIndex(existingColorIndices: [Int]) -> Int {
        guard tileColorCount > 0 else { return 0 }
        let used = Set(existingColorIndices.map { ((($0 % tileColorCount) + tileColorCount) % tileColorCount) })
        for index in 0..<tileColorCount where !used.contains(index) {
            return index
        }
        return existingColorIndices.count % tileColorCount
    }
}

extension Profile: CustomStringConvertible {
    /// Profiles carry no secret; keep logging terse and stable.
    public var description: String {
        "Profile(id: \(id), name: \(name))"
    }
}

extension Profile {
    /// Returns a copy of this profile mapped to the given Seerr user (its id +
    /// cached display fields), or with the mapping cleared when `id` is `nil`
    /// (reverts to requesting as admin). Non-secret metadata only.
    public func settingSeerrUser(id: Int?, name: String? = nil, avatarURL: String? = nil) -> Profile {
        var copy = self
        copy.seerrUserID = id
        copy.seerrUserName = id == nil ? nil : name
        copy.seerrUserAvatarURL = id == nil ? nil : avatarURL
        return copy
    }
}

/// One profile's Plex Home-user selection for ONE Plex account. A profile
/// can hold several of these (keyed by `Account.id`) so each distinct
/// `plex.tv` sign-in plays as the right Home user.
public struct PlexHomeUserBinding: Codable, Hashable, Sendable {
    public var homeUserID: String
    public var name: String
    public var avatarURL: String?
    public var requiresPIN: Bool?

    public init(homeUserID: String, name: String, avatarURL: String? = nil, requiresPIN: Bool? = nil) {
        self.homeUserID = homeUserID
        self.name = name
        self.avatarURL = avatarURL
        self.requiresPIN = requiresPIN
    }
}

extension Profile {
    /// Returns this profile's Plex Home-user binding for `accountID`, falling
    /// back to the legacy single-mapping fields (`plexHomeUserID` et al.)
    /// when no per-account dict exists yet. This is the **upgrade path**:
    /// profiles encoded before the per-account map shipped continue to work
    /// transparently.
    public func homeUserBinding(forPlexAccount accountID: String) -> PlexHomeUserBinding? {
        if let dict = plexHomeUserBindings, let entry = dict[accountID] {
            return entry
        }
        // Legacy single-mapping fallback: only honor it when it actually
        // targets this account.
        guard plexHomeUserAccountID == accountID,
              let id = plexHomeUserID else { return nil }
        return PlexHomeUserBinding(
            homeUserID: id,
            name: plexHomeUserName ?? "",
            avatarURL: plexHomeUserAvatarURL,
            requiresPIN: plexHomeUserRequiresPIN
        )
    }

    /// Writes (or clears) the Plex Home-user binding for `accountID`. Returns
    /// the updated profile. Authoritative storage is the dict; the legacy
    /// single-mapping fields are mirrored to the just-written entry so older
    /// readers still see a coherent (most-recent) selection. Clearing the
    /// last entry clears the legacy fields too.
    public func settingHomeUserBinding(_ binding: PlexHomeUserBinding?, forPlexAccount accountID: String) -> Profile {
        var copy = self
        var dict = copy.plexHomeUserBindings ?? [:]
        // Seed dict from legacy fields on first migration so we don't lose
        // an existing single mapping when we add a NEW per-account entry.
        if copy.plexHomeUserBindings == nil,
           let legacyID = copy.plexHomeUserID,
           let legacyAcct = copy.plexHomeUserAccountID,
           dict[legacyAcct] == nil {
            dict[legacyAcct] = PlexHomeUserBinding(
                homeUserID: legacyID,
                name: copy.plexHomeUserName ?? "",
                avatarURL: copy.plexHomeUserAvatarURL,
                requiresPIN: copy.plexHomeUserRequiresPIN
            )
        }
        if let binding {
            dict[accountID] = binding
            copy.plexHomeUserID = binding.homeUserID
            copy.plexHomeUserName = binding.name
            copy.plexHomeUserAccountID = accountID
            copy.plexHomeUserRequiresPIN = binding.requiresPIN
            copy.plexHomeUserAvatarURL = binding.avatarURL
        } else {
            dict.removeValue(forKey: accountID)
            if copy.plexHomeUserAccountID == accountID {
                copy.plexHomeUserID = nil
                copy.plexHomeUserName = nil
                copy.plexHomeUserAccountID = nil
                copy.plexHomeUserRequiresPIN = nil
                copy.plexHomeUserAvatarURL = nil
            }
            // If another binding still exists, surface one of them in the
            // legacy fields so an older build/codepath that only reads them
            // sees *something* sane (deterministic — the lex-first key).
            if copy.plexHomeUserAccountID == nil,
               let next = dict.sorted(by: { $0.key < $1.key }).first {
                copy.plexHomeUserAccountID = next.key
                copy.plexHomeUserID = next.value.homeUserID
                copy.plexHomeUserName = next.value.name
                copy.plexHomeUserAvatarURL = next.value.avatarURL
                copy.plexHomeUserRequiresPIN = next.value.requiresPIN
            }
        }
        copy.plexHomeUserBindings = dict.isEmpty ? nil : dict
        return copy
    }
}
