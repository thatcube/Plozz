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

    /// Optional emoji used as the profile avatar (opt-in). When non-nil the
    /// avatar renders this emoji as text on the colored tile — native Apple
    /// Color Emoji drawn by the system, so nothing is bundled or redistributed.
    /// Takes precedence over `avatarSymbol` but sits below `avatarImageURL`
    /// (a borrowed photo wins). Decoded with `decodeIfPresent` so older profile
    /// JSON without this field migrates to `nil` cleanly.
    public var avatarEmoji: String?

    /// Optional background colour index for an **emoji** avatar. `nil` (the
    /// default) renders the emoji on a theme-neutral disc — colours often clash
    /// with a multicolour emoji, so neutral is the sensible default (like
    /// Memoji). A non-nil value paints the emoji on that palette colour for
    /// people who want it. Only meaningful when `avatarEmoji` is set; symbols
    /// always use `colorIndex`. Migration-safe (`decodeIfPresent`).
    public var avatarEmojiColorIndex: Int?

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

    /// Optional PIN gate. `nil` (the default) = anyone on this device can open
    /// the profile, which is the right default and the only behaviour that
    /// existed before.
    ///
    /// Holds a salted verifier, never the PIN — see `ProfileLock`. It rides the
    /// synced profile record deliberately: a lock that only exists on the Apple
    /// TV is not a lock, because the same profile is one tap away on the iPhone.
    /// The flip side is that with iCloud Sync off it *is* device-only, which the
    /// setup screen says out loud.
    public var lock: ProfileLock?
    /// Field-level conflict revision for `lock`. See `ProfileLockRevision`.
    public var lockRevision: ProfileLockRevision?

    /// Whether this is a **Kids Profile**: shared, household-level settings are
    /// hidden while it's active.
    ///
    /// The other half of the lock. A lock keeps a child *out* of the grown-ups'
    /// profiles; this keeps them from wrecking the household from inside their
    /// own — removing servers, deleting profiles, signing everything out. Both
    /// are needed, because the destructive controls live in a section every
    /// profile can reach.
    ///
    /// Only settable from a profile that isn't itself a Kids Profile, so it
    /// can't be switched off from inside. Synced, for the same reason the lock
    /// is: a restriction that applied on one device wouldn't be a restriction.
    ///
    /// NOTE: this restricts *settings*, not *content* — Plozz has no maturity
    /// filtering yet, so a Kids Profile still sees everything its libraries
    /// contain. Named for what it will grow into, but don't oversell it in copy.
    ///
    /// Optional purely for migration: profiles encoded before this field existed
    /// decode as `nil`, and the synthesized encoder omits `nil` rather than
    /// writing `false`, so an older peer's bytes round-trip unchanged (the sync
    /// anti-clobber invariant). Read it through `isKids`.
    public var isKidsProfile: Bool?

    /// Whether this profile has never been through its setup step.
    ///
    /// A brand-new profile inherits every server in the household (no explicit
    /// membership means "all of them"), so left alone it would immediately
    /// import every server's native watchlist and be born holding the
    /// household's aggregate list. While this is `true` the native import is
    /// skipped entirely — the profile's own local state still hydrates — and it
    /// runs once, properly, after the person has said which servers this profile
    /// uses and who it watches as.
    ///
    /// Optional for migration: existing profiles decode `nil`, which means
    /// "set up long ago", so nothing changes for them.
    public var isAwaitingSetup: Bool?

    /// Accounts this profile has switched ON but not yet said who it watches as.
    ///
    /// PERSISTED, unlike the in-memory prompt that presents the question. The
    /// question is only half the job: enabling a Plex server immediately reloads
    /// accounts, which schedules a watchlist import, and with no Home-user
    /// binding that import reads the server as the account OWNER and pulls their
    /// list in — before the question has been answered, and again on every launch
    /// after, since an in-memory prompt doesn't survive a restart.
    ///
    /// While this is non-empty the native import is deferred exactly as
    /// `isAwaitingSetup` defers it. Optional, and cleared to absence rather than
    /// `[]`, so existing profiles decode as "nothing owed" and the record stays
    /// byte-stable for the sync layer.
    public var accountsAwaitingIdentity: [String]?

    /// Accounts this profile still owes an identity answer for.
    public var pendingIdentityAccountIDs: [String] {
        accountsAwaitingIdentity ?? []
    }

    /// Whether the setup step still owes this profile a pass. See `isAwaitingSetup`.
    public var needsSetup: Bool {
        get { isAwaitingSetup == true }
        set { isAwaitingSetup = newValue ? true : nil }
    }

    /// Whether this profile plays as a Plex Home user that already asks for a
    /// PIN, so one entry can be offered to satisfy both gates.
    ///
    /// Shared because four screens across both shells asked the same question
    /// with their own copy of it, and a lock offer that disagrees with the lock
    /// screen about whether PIN reuse applies is a confusing way to fail.
    public var playsAsPINProtectedPlexUser: Bool {
        if plexHomeUserRequiresPIN == true { return true }
        return plexHomeUserBindings?.values.contains { $0.requiresPIN == true } ?? false
    }

    /// Revision used for conflict resolution, including an immediate baseline for
    /// locks created by an older build before `lockRevision` existed.
    public var effectiveLockRevision: ProfileLockRevision? {
        lockRevision ?? lock.map { ProfileLockRevision.legacy(for: $0) }
    }

    /// Adds, changes or removes the lock and advances its field-level revision.
    public mutating func replaceLock(with newLock: ProfileLock?) {
        lockRevision = .next(after: effectiveLockRevision)
        lock = newLock
    }

    /// Whether an answer is owed about who this profile watches as on any of
    /// `accountIDs`. See `accountsAwaitingIdentity`.
    ///
    /// Scoped to accounts that are actually signed in on THIS device rather than
    /// asking "is anything pending at all". The two requirements pull against
    /// each other: questions must be recorded generously — synced membership can
    /// enable a server this device hasn't signed into yet, and refusing to note
    /// it there means the leak simply happens later, once it does — but a
    /// question about an account that isn't here must not gate anything, or a
    /// server that never arrives defers every import forever.
    ///
    /// Narrowing at the point of USE satisfies both: an account that isn't signed
    /// in has nothing to import from, so it can't leak and mustn't gate; the
    /// question stays on the record and starts gating the moment it arrives.
    public func awaitsIdentity(amongAccounts accountIDs: some Collection<String>) -> Bool {
        let pending = pendingIdentityAccountIDs
        guard !pending.isEmpty else { return false }
        return accountIDs.contains { pending.contains($0) }
    }

    /// Whether this profile is restricted. See `isKidsProfile`.
    public var isKids: Bool {
        get { isKidsProfile == true }
        set { isKidsProfile = newValue ? true : nil }
    }

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
        avatarEmoji: String? = nil,
        avatarEmojiColorIndex: Int? = nil,
        seerrUserID: Int? = nil,
        seerrUserName: String? = nil,
        seerrUserAvatarURL: String? = nil,
        lock: ProfileLock? = nil,
        lockRevision: ProfileLockRevision? = nil,
        isKidsProfile: Bool? = nil,
        isAwaitingSetup: Bool? = nil
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
        self.avatarEmoji = avatarEmoji
        self.avatarEmojiColorIndex = avatarEmojiColorIndex
        self.seerrUserID = seerrUserID
        self.seerrUserName = seerrUserName
        self.seerrUserAvatarURL = seerrUserAvatarURL
        self.lock = lock
        self.lockRevision = lockRevision
        self.isKidsProfile = isKidsProfile
        self.isAwaitingSetup = isAwaitingSetup
    }

    /// Whether opening this profile needs a PIN.
    public var isLocked: Bool { lock != nil }

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
    /// Stable, language-independent identity. Previously derived from `title`,
    /// which would have changed the category's id — and its SwiftUI identity —
    /// the moment the title was localized.
    public let id: String
    public let title: LocalizedStringResource
    public let symbols: [String]

    public init(id: String, title: LocalizedStringResource, symbols: [String]) {
        self.id = id
        self.title = title
        self.symbols = symbols
    }

    // LocalizedStringResource is Equatable but not Hashable, so the synthesized
    // conformance no longer compiles. Keying on `id` alone is correct regardless:
    // two categories are the same category when they have the same id, whatever
    // language their title happens to be showing.
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// One offered emoji avatar plus the minimum OS that renders it. Newer emoji
/// (e.g. Emoji 16.0, which Apple first shipped in tvOS 18.4) would render as an
/// empty "tofu" box on an older OS, so each entry carries the floor it needs;
/// the picker filters to what the current device can actually draw. `0` means
/// "available on the app's deployment floor" (no gating needed).
public struct AvatarEmoji: Hashable, Sendable, Identifiable {
    public var id: String { value }
    /// The emoji character(s), rendered as native system Color Emoji.
    public let value: String
    public let minMajor: Int
    public let minMinor: Int

    public init(_ value: String, minMajor: Int = 0, minMinor: Int = 0) {
        self.value = value
        self.minMajor = minMajor
        self.minMinor = minMinor
    }

    /// Whether this emoji renders on the given OS version. Ungated entries
    /// (`minMajor == 0`) are always available.
    public func isAvailable(osMajor: Int, osMinor: Int) -> Bool {
        if minMajor == 0 { return true }
        return (osMajor, osMinor) >= (minMajor, minMinor)
    }
}

/// A labelled group of emoji avatars (one browsable section in the picker).
public struct AvatarEmojiCategory: Hashable, Sendable, Identifiable {
    /// Stable, language-independent identity — see `AvatarSymbolCategory.id`.
    public let id: String
    public let title: LocalizedStringResource
    public let emojis: [AvatarEmoji]

    public init(id: String, title: LocalizedStringResource, emojis: [AvatarEmoji]) {
        self.id = id
        self.title = title
        self.emojis = emojis
    }

    // LocalizedStringResource is Equatable but not Hashable, so the synthesized
    // conformance no longer compiles. Keying on `id` alone is correct regardless:
    // two categories are the same category when they have the same id, whatever
    // language their title happens to be showing.
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }


    /// The emoji in this category the given OS can actually render, in order.
    public func availableEmojis(osMajor: Int, osMinor: Int) -> [AvatarEmoji] {
        emojis.filter { $0.isAvailable(osMajor: osMajor, osMinor: osMinor) }
    }
}

extension Profile {
    /// Curated, tvOS-friendly SF Symbols offered as profile avatars, grouped so
    /// the picker can present browsable sections. **Every symbol here is verified
    /// available at Plozz's tvOS 18.0 baseline (SF Symbols 6.0)** against the SDK's
    /// `name_availability.plist` — a blank tile means a bad name, so don't add a
    /// symbol without confirming its tvOS 18.0 availability. The very first symbol
    /// of the first category is the app-wide default avatar
    /// (`defaultAvatarSymbols[0]`), so keep `person.crop.circle.fill` leading —
    /// several call sites rely on it. Each category holds exactly 8 symbols so it
    /// renders as one clean row in the editor.
    public static let avatarSymbolCategories: [AvatarSymbolCategory] = [
        AvatarSymbolCategory(id: "people", title: "People", symbols: [
            "person.crop.circle.fill",
            "person.fill",
            "person.2.fill",
            "figure.walk",
            "figure.and.child.holdinghands",
            "graduationcap.fill",
            "eyeglasses",
            "mustache.fill"
        ]),
        AvatarSymbolCategory(id: "faces-fun", title: "Faces & Fun", symbols: [
            "face.smiling.inverse",
            "sunglasses.fill",
            "heart.fill",
            "crown.fill",
            "sparkles",
            "party.popper.fill",
            "flame.fill",
            "wand.and.stars"
        ]),
        AvatarSymbolCategory(id: "sports-fitness", title: "Sports & Fitness", symbols: [
            "figure.run",
            "figure.basketball",
            "figure.american.football",
            "figure.boxing",
            "figure.golf",
            "dumbbell.fill",
            "soccerball",
            "trophy.fill"
        ]),
        AvatarSymbolCategory(id: "gaming-tech", title: "Gaming & Tech", symbols: [
            "gamecontroller.fill",
            "dpad.fill",
            "die.face.6",
            "puzzlepiece.fill",
            "keyboard.fill",
            "cpu",
            "desktopcomputer",
            "visionpro"
        ]),
        AvatarSymbolCategory(id: "music-audio", title: "Music & Audio", symbols: [
            "music.note",
            "music.mic",
            "guitars.fill",
            "headphones",
            "waveform",
            "radio.fill",
            "speaker.wave.3.fill",
            "tuningfork"
        ]),
        AvatarSymbolCategory(id: "movies-tv", title: "Movies & TV", symbols: [
            "film.fill",
            "tv.fill",
            "ticket.fill",
            "theatermasks.fill",
            "play.rectangle.fill",
            "rectangle.stack.fill",
            "star.fill",
            "camera.fill"
        ]),
        AvatarSymbolCategory(id: "food-drink", title: "Food & Drink", symbols: [
            "fork.knife",
            "birthday.cake.fill",
            "wineglass.fill",
            "mug.fill",
            "cup.and.saucer.fill",
            "carrot.fill",
            "takeoutbag.and.cup.and.straw.fill",
            "popcorn.fill"
        ]),
        AvatarSymbolCategory(id: "animals", title: "Animals", symbols: [
            "pawprint.fill",
            "dog.fill",
            "cat.fill",
            "bird.fill",
            "fish.fill",
            "hare.fill",
            "tortoise.fill",
            "lizard.fill"
        ]),
        AvatarSymbolCategory(id: "nature-weather", title: "Nature & Weather", symbols: [
            "leaf.fill",
            "tree.fill",
            "mountain.2.fill",
            "tent.fill",
            "cloud.sun.fill",
            "cloud.bolt.fill",
            "snowflake",
            "rainbow"
        ]),
        AvatarSymbolCategory(id: "space-science", title: "Space & Science", symbols: [
            "moon.stars.fill",
            "sun.max.fill",
            "atom",
            "brain.head.profile",
            "bolt.fill",
            "laser.burst",
            "antenna.radiowaves.left.and.right",
            "globe.americas.fill"
        ]),
        AvatarSymbolCategory(id: "travel-hobbies", title: "Travel & Hobbies", symbols: [
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

    /// Curated, fun **native Apple emoji** offered as profile avatars, grouped
    /// into horizontally browsable categories. Rendered
    /// as *text* via the system Color Emoji font — nothing is bundled or
    /// redistributed — so this is legally clean on Apple platforms.
    /// Personality-forward but tightly themed, from real usage/PFP-culture
    /// research (💀 🗿 🤡 🦊 👽 🤖 🐉 …).
    ///
    /// Every entry is Unicode Emoji ≤ 15.1, which Apple ships on the app's tvOS
    /// floor, so none need version gating. The `AvatarEmoji` type still carries a
    /// `minMajor`/`minMinor` so a future, newer glyph can be offered with an
    /// automatic fallback (hidden on older systems) rather than showing an empty
    /// "tofu" box.
    public static let avatarEmojiCategories: [AvatarEmojiCategory] = [
        AvatarEmojiCategory(id: "faces", title: "Faces", emojis: [
            AvatarEmoji("😎"), AvatarEmoji("🤠"), AvatarEmoji("😈"), AvatarEmoji("🤓"),
            AvatarEmoji("🥴"), AvatarEmoji("🫠"), AvatarEmoji("🙃"), AvatarEmoji("🤨"),
            AvatarEmoji("😀"), AvatarEmoji("🥳"), AvatarEmoji("🤩"), AvatarEmoji("🧐"),
            AvatarEmoji("🥸"), AvatarEmoji("😴"), AvatarEmoji("🤯"), AvatarEmoji("🥶")
        ]),
        AvatarEmojiCategory(id: "reactions", title: "Reactions", emojis: [
            AvatarEmoji("💀"), AvatarEmoji("🗿"), AvatarEmoji("🤡"), AvatarEmoji("👀"),
            AvatarEmoji("🧢"), AvatarEmoji("😭"), AvatarEmoji("🫡"), AvatarEmoji("💯"),
            AvatarEmoji("✨"), AvatarEmoji("🤌"), AvatarEmoji("👏"), AvatarEmoji("🙌"),
            AvatarEmoji("🫶"), AvatarEmoji("🫣"), AvatarEmoji("🤪"), AvatarEmoji("😤")
        ]),
        AvatarEmojiCategory(id: "cute-animals", title: "Cute Animals", emojis: [
            AvatarEmoji("🐱"), AvatarEmoji("🐶"), AvatarEmoji("🐼"), AvatarEmoji("🦊"),
            AvatarEmoji("🐰"), AvatarEmoji("🐧"), AvatarEmoji("🦔"), AvatarEmoji("🪿"),
            AvatarEmoji("🐨"), AvatarEmoji("🐯"), AvatarEmoji("🐸"), AvatarEmoji("🐵"),
            AvatarEmoji("🐹"), AvatarEmoji("🦦"), AvatarEmoji("🦥"), AvatarEmoji("🐙")
        ]),
        AvatarEmojiCategory(id: "beasts", title: "Beasts", emojis: [
            AvatarEmoji("🦁"), AvatarEmoji("🐺"), AvatarEmoji("🦅"), AvatarEmoji("🦈"),
            AvatarEmoji("🦖"), AvatarEmoji("🐉"), AvatarEmoji("🐦‍🔥"), AvatarEmoji("🫎"),
            AvatarEmoji("🐻"), AvatarEmoji("🐗"), AvatarEmoji("🦬"), AvatarEmoji("🐊"),
            AvatarEmoji("🦂"), AvatarEmoji("🦍"), AvatarEmoji("🐲"), AvatarEmoji("🦇")
        ]),
        AvatarEmojiCategory(id: "fantasy-sci-fi", title: "Fantasy & Sci-Fi", emojis: [
            AvatarEmoji("👽"), AvatarEmoji("🤖"), AvatarEmoji("👾"), AvatarEmoji("🧙"),
            AvatarEmoji("🧛"), AvatarEmoji("🧟"), AvatarEmoji("🦄"), AvatarEmoji("👻"),
            AvatarEmoji("🧚"), AvatarEmoji("🧜"), AvatarEmoji("🧞"), AvatarEmoji("🧝"),
            AvatarEmoji("🥷"), AvatarEmoji("🦸"), AvatarEmoji("🦹"), AvatarEmoji("🧌")
        ]),
        AvatarEmojiCategory(id: "food-drink", title: "Food & Drink", emojis: [
            AvatarEmoji("🍕"), AvatarEmoji("🍔"), AvatarEmoji("🍣"), AvatarEmoji("🌮"),
            AvatarEmoji("🍦"), AvatarEmoji("🍩"), AvatarEmoji("🧋"), AvatarEmoji("🍿"),
            AvatarEmoji("🍓"), AvatarEmoji("🍉"), AvatarEmoji("🍪"), AvatarEmoji("🧁"),
            AvatarEmoji("🥐"), AvatarEmoji("🥑"), AvatarEmoji("🍜"), AvatarEmoji("🧀")
        ]),
        AvatarEmojiCategory(id: "play-hobbies", title: "Play & Hobbies", emojis: [
            AvatarEmoji("🎮"), AvatarEmoji("🏆"), AvatarEmoji("🎸"), AvatarEmoji("🎧"),
            AvatarEmoji("⚽"), AvatarEmoji("🏀"), AvatarEmoji("🎲"), AvatarEmoji("🎬"),
            AvatarEmoji("🏈"), AvatarEmoji("⚾"), AvatarEmoji("🏐"), AvatarEmoji("🎾"),
            AvatarEmoji("🛹"), AvatarEmoji("🎨"), AvatarEmoji("📚"), AvatarEmoji("🚀")
        ]),
        AvatarEmojiCategory(id: "nature-sky", title: "Nature & Sky", emojis: [
            AvatarEmoji("🌙"), AvatarEmoji("⭐"), AvatarEmoji("🌈"), AvatarEmoji("🪐"),
            AvatarEmoji("☀️"), AvatarEmoji("⚡"), AvatarEmoji("🌊"), AvatarEmoji("🪼"),
            AvatarEmoji("🌻"), AvatarEmoji("🌵"), AvatarEmoji("🍄"), AvatarEmoji("🌲"),
            AvatarEmoji("🌸"), AvatarEmoji("❄️"), AvatarEmoji("☁️"), AvatarEmoji("🌋")
        ]),
        AvatarEmojiCategory(id: "adventure", title: "Adventure", emojis: [
            AvatarEmoji("👑"), AvatarEmoji("💎"), AvatarEmoji("🔮"), AvatarEmoji("🗡️"),
            AvatarEmoji("🛡️"), AvatarEmoji("🏴‍☠️"), AvatarEmoji("🔥"), AvatarEmoji("🧭"),
            AvatarEmoji("🏕️"), AvatarEmoji("🗺️"), AvatarEmoji("⛵"), AvatarEmoji("🚁"),
            AvatarEmoji("🏎️"), AvatarEmoji("🎒"), AvatarEmoji("⚓"), AvatarEmoji("🪂")
        ]),
        AvatarEmojiCategory(id: "flair", title: "Flair", emojis: [
            AvatarEmoji("💅"), AvatarEmoji("🧊"), AvatarEmoji("🫧"), AvatarEmoji("🤙"),
            AvatarEmoji("💫"), AvatarEmoji("🪄"), AvatarEmoji("💥"), AvatarEmoji("🎀"),
            AvatarEmoji("🕶️"), AvatarEmoji("🎩"), AvatarEmoji("🪩"), AvatarEmoji("🎉"),
            AvatarEmoji("🎊"), AvatarEmoji("💡"), AvatarEmoji("🔔"), AvatarEmoji("🧿")
        ]),
        AvatarEmojiCategory(id: "hearts", title: "Hearts", emojis: [
            AvatarEmoji("❤️"), AvatarEmoji("🧡"), AvatarEmoji("💛"), AvatarEmoji("💚"),
            AvatarEmoji("💙"), AvatarEmoji("💜"), AvatarEmoji("🖤"), AvatarEmoji("🩷"),
            AvatarEmoji("🤍"), AvatarEmoji("🤎"), AvatarEmoji("💔"), AvatarEmoji("💕"),
            AvatarEmoji("💖"), AvatarEmoji("💘"), AvatarEmoji("💝"), AvatarEmoji("💞")
        ])
    ]

    /// A random fun emoji for a brand-new profile, so auto-created / lazily
    /// created profiles get a playful emoji avatar instead of a plain symbol.
    /// Drawn only from the ungated (always-renderable) emoji so it's safe on any
    /// supported OS.
    public static func randomAvatarEmoji(excluding used: Set<String> = []) -> String {
        let pool = avatarEmojiCategories.flatMap(\.emojis).filter { $0.minMajor == 0 }
        let unused = pool.filter { !used.contains($0.value) }
        return (unused.isEmpty ? pool : unused).randomElement()?.value ?? "😎"
    }

    /// Palette indices for `colorIndex`. Resolved to concrete colors in the UI
    /// layer so `CoreModels` stays Foundation-only. Keep in sync with
    /// `ProfileTileColor.palette` (the UI palette has this many colours).
    public static let tileColorCount = 40

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
    public var description: String {  // l10n:content — developer-facing diagnostic
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
    /// Whether this is a **managed** Plex Home user — one created inside someone
    /// else's Plex account, with no email or login of its own.
    ///
    /// Recorded because a managed user has no Plex Discover watchlist: writing to
    /// it returns 401/403, so Plozz must not route watchlist changes at that
    /// account while a profile watches as one. Without this the mutations sat in
    /// the outbox as `waitingForAuthentication` forever, waiting for an
    /// authentication that can never arrive.
    ///
    /// Optional for migration: bindings written before this decode as `nil`,
    /// meaning "unknown", treated as not-managed so nothing changes for an
    /// ordinary full account.
    public var isManaged: Bool?

    public init(
        homeUserID: String,
        name: String,
        avatarURL: String? = nil,
        requiresPIN: Bool? = nil,
        isManaged: Bool? = nil
    ) {
        self.homeUserID = homeUserID
        self.name = name
        self.avatarURL = avatarURL
        self.requiresPIN = requiresPIN
        self.isManaged = isManaged
    }
}

extension Profile {
    /// Stable identity of who this profile plays as on each active Plex account.
    ///
    /// This is UI/content identity, not credential identity. Plex may rotate the
    /// access token during a background refresh while the person remains exactly
    /// the same; keying SwiftUI on that token-generation counter destroyed and
    /// rebuilt the entire Home screen, making the hero visibly load again.
    public func plexPlaybackIdentityKey(for accounts: [Account]) -> String {
        accounts
            .filter { $0.server.provider == .plex }
            .map { account in
                let homeUserID = homeUserBinding(forPlexAccount: account.id)?
                    .homeUserID ?? "owner"
                return "\(account.id)#\(homeUserID)"
            }
            .sorted()
            .joined(separator: "|")
    }

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
