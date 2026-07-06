import Foundation

/// A profile's **Home & library display preferences**: how libraries are laid out
/// on Home, which libraries are available at all, and which rows appear on Home.
///
/// Persisted as one per-profile value so it can be saved, broadcast, and rebuilt
/// on a profile switch in one place.
///
/// - `mergeLibrariesOnHome` — the all-or-nothing "merge every library's content
///   into unified cross-server rows" switch. `true` (the default) is the classic
///   behaviour; `false` lets each library contribute its own opt-in rows.
/// - `disabledKeys` — libraries turned **off app-wide** (hidden everywhere: Home,
///   Search, Music, browse).
/// - `excludedKeys` — libraries hidden from **Home only** (the merged-mode
///   "show on Home" opt-out; still available in Search / Music / browse).
/// - `disabledGlobalHomeRows` — the global Home rows (Continue Watching / Watchlist
///   / Recently Added) the user has turned **off** (opt-out; default all on). The
///   hero's on/off lives in `HeroSettings`, not here.
/// - `enabledLibraryHomeRows` — the per-library rows the user has **opted in** to
///   showing on Home in unmerged mode (default none, so Home stays lean). Keyed
///   `"<accountID>:<libraryID>:<rowKind>"`.
///
/// Library keys are `AggregatedLibrary.key` (`"accountID:libraryID"`).
///
/// ### Predicate vocabulary (read before touching callers)
/// - ``isEnabled(_:)`` — app-wide availability (`!disabledKeys`).
/// - ``isShownOnHome(_:)`` — the Home-only bit (`!excludedKeys`), independent of
///   enabled so re-enabling a library restores its previous Home choice.
/// - ``isVisibleOnHome(_:)`` — enabled **and** shown; what Home rendering /
///   aggregation use. ``isVisible(_:)`` is a compatibility alias.
public struct HomeLibraryVisibility: Codable, Equatable, Sendable {
    /// Whether Home merges every library's content into unified cross-server rows
    /// (`true`, the classic behaviour) or lets each library contribute its own
    /// opt-in rows (`false`).
    public var mergeLibrariesOnHome: Bool

    /// Keys of libraries turned off **app-wide** — hidden from Home, Search, Music
    /// and browse alike.
    public var disabledKeys: Set<String>

    /// Keys of libraries hidden from **Home only** (merged-mode opt-out). Still
    /// available everywhere else.
    public var excludedKeys: Set<String>

    /// Raw values of the global Home rows the user has turned **off** (opt-out, so
    /// the default empty set = every global row on). See ``HomeGlobalRow``.
    public var disabledGlobalHomeRows: Set<String>

    /// Per-library rows the user has **opted in** to on Home (unmerged mode).
    /// Opt-in, so the default empty set keeps Home lean. Keys are
    /// `"<accountID>:<libraryID>:<rowKind>"` (see ``libraryRowKey(_:kind:)``).
    public var enabledLibraryHomeRows: Set<String>

    /// Whether the one-time per-library row seeding has already run (see
    /// ``seedLibraryRowsIfNeeded(_:)``). Tracked explicitly rather than inferred
    /// from `enabledLibraryHomeRows.isEmpty`, so a user who unmerges and then
    /// turns *every* per-library row off keeps that "nothing on Home" choice
    /// across a later merge on→off re-toggle instead of being re-seeded.
    public var hasSeededLibraryRows: Bool

    public init(
        mergeLibrariesOnHome: Bool = true,
        disabledKeys: Set<String> = [],
        excludedKeys: Set<String> = [],
        disabledGlobalHomeRows: Set<String> = [],
        enabledLibraryHomeRows: Set<String> = [],
        hasSeededLibraryRows: Bool = false
    ) {
        self.mergeLibrariesOnHome = mergeLibrariesOnHome
        self.disabledKeys = disabledKeys
        self.excludedKeys = excludedKeys
        self.disabledGlobalHomeRows = disabledGlobalHomeRows
        self.enabledLibraryHomeRows = enabledLibraryHomeRows
        self.hasSeededLibraryRows = hasSeededLibraryRows
    }

    /// The default: merge on, nothing disabled/hidden, every global row on, no
    /// per-library rows — matching pre-customization behaviour.
    public static let `default` = HomeLibraryVisibility()

    // MARK: - Library availability predicates

    /// Whether the library with `key` is available **app-wide** (not disabled).
    public func isEnabled(_ key: String) -> Bool {
        !disabledKeys.contains(key)
    }

    /// The Home-only visibility bit (merged mode), independent of enabled.
    public func isShownOnHome(_ key: String) -> Bool {
        !excludedKeys.contains(key)
    }

    /// Whether the library appears on Home: enabled **and** shown.
    public func isVisibleOnHome(_ key: String) -> Bool {
        isEnabled(key) && isShownOnHome(key)
    }

    /// Compatibility alias for ``isVisibleOnHome(_:)``.
    public func isVisible(_ key: String) -> Bool {
        isVisibleOnHome(key)
    }

    // MARK: - Library availability mutation

    /// Turns a library on/off **app-wide** (leaves the Home-only choice intact).
    public mutating func setEnabled(_ enabled: Bool, for key: String) {
        if enabled {
            disabledKeys.remove(key)
        } else {
            disabledKeys.insert(key)
        }
    }

    /// Sets whether a library is shown on **Home only** (merged-mode opt-out).
    public mutating func setShownOnHome(_ shown: Bool, for key: String) {
        if shown {
            excludedKeys.remove(key)
        } else {
            excludedKeys.insert(key)
        }
    }

    /// Compatibility alias for ``setShownOnHome(_:for:)``.
    public mutating func setVisible(_ visible: Bool, for key: String) {
        setShownOnHome(visible, for: key)
    }

    // MARK: - Global Home rows (opt-out)

    /// Whether a global Home row is shown (default on).
    public func isGlobalRowEnabled(_ row: HomeGlobalRow) -> Bool {
        !disabledGlobalHomeRows.contains(row.rawValue)
    }

    /// Shows/hides a global Home row.
    public mutating func setGlobalRowEnabled(_ enabled: Bool, for row: HomeGlobalRow) {
        if enabled {
            disabledGlobalHomeRows.remove(row.rawValue)
        } else {
            disabledGlobalHomeRows.insert(row.rawValue)
        }
    }

    // MARK: - Per-library Home rows (opt-in)

    /// The persistence key for a per-library row: `"<libraryKey>:<rowKind>"`.
    public static func libraryRowKey(_ libraryKey: String, kind: LibraryHomeRowKind) -> String {
        "\(libraryKey):\(kind.rawValue)"
    }

    /// Whether a per-library row is opted in to Home (default off).
    public func isLibraryRowEnabled(_ libraryKey: String, kind: LibraryHomeRowKind) -> Bool {
        enabledLibraryHomeRows.contains(Self.libraryRowKey(libraryKey, kind: kind))
    }

    /// Opts a per-library row in/out of Home.
    public mutating func setLibraryRowEnabled(_ enabled: Bool, libraryKey: String, kind: LibraryHomeRowKind) {
        let key = Self.libraryRowKey(libraryKey, kind: kind)
        if enabled {
            enabledLibraryHomeRows.insert(key)
        } else {
            enabledLibraryHomeRows.remove(key)
        }
    }

    /// Seeds the given per-library rows **on**, but only the first time the user
    /// unmerges (tracked by ``hasSeededLibraryRows``).
    ///
    /// Turning the merge switch **off** is a clear "I want each library's own
    /// rows" signal, so the first time that happens we start with everything on
    /// and let the user pare it back — much better than dropping them onto an
    /// empty Home. Keying off an explicit `hasSeededLibraryRows` flag (rather than
    /// `enabledLibraryHomeRows.isEmpty`) means a later re-toggle (merge on, then
    /// off again) never re-seeds — including when the user has deliberately turned
    /// *every* per-library row off, which an emptiness check couldn't distinguish
    /// from first-run. Only sets the flag when it actually seeds (rows non-empty),
    /// so a toggle made before library discovery finishes is retried later.
    /// Returns `true` when it seeded (so the caller can persist).
    @discardableResult
    public mutating func seedLibraryRowsIfNeeded(_ rows: [(libraryKey: String, kind: LibraryHomeRowKind)]) -> Bool {
        guard !hasSeededLibraryRows, !rows.isEmpty else { return false }
        for row in rows {
            enabledLibraryHomeRows.insert(Self.libraryRowKey(row.libraryKey, kind: row.kind))
        }
        hasSeededLibraryRows = true
        return true
    }

    // MARK: - Codable (backward compatible)

    private enum CodingKeys: String, CodingKey {
        case mergeLibrariesOnHome
        case disabledKeys
        case excludedKeys
        case disabledGlobalHomeRows
        case enabledLibraryHomeRows
        case hasSeededLibraryRows
    }

    /// Decodes leniently so a pre-existing blob (which had only `excludedKeys`, or
    /// later `mergeLibrariesOnHome`/`disabledKeys`) still loads: missing fields
    /// fall back to the defaults (merge on, every global row on, no per-library
    /// rows), so an upgrading install sees zero Home behaviour change until it opts
    /// in. A since-removed `mergeContinueWatchingOnHome` key is simply ignored.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.mergeLibrariesOnHome = try container.decodeIfPresent(Bool.self, forKey: .mergeLibrariesOnHome) ?? true
        self.disabledKeys = try container.decodeIfPresent(Set<String>.self, forKey: .disabledKeys) ?? []
        self.excludedKeys = try container.decodeIfPresent(Set<String>.self, forKey: .excludedKeys) ?? []
        self.disabledGlobalHomeRows = try container.decodeIfPresent(Set<String>.self, forKey: .disabledGlobalHomeRows) ?? []
        self.enabledLibraryHomeRows = try container.decodeIfPresent(Set<String>.self, forKey: .enabledLibraryHomeRows) ?? []
        // Migration: a blob predating this flag that already has opted-in rows was
        // clearly seeded before, so treat it as seeded — otherwise the first
        // post-upgrade merge re-toggle would re-seed over its customization.
        self.hasSeededLibraryRows = (try container.decodeIfPresent(Bool.self, forKey: .hasSeededLibraryRows) ?? false)
            || !self.enabledLibraryHomeRows.isEmpty
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mergeLibrariesOnHome, forKey: .mergeLibrariesOnHome)
        try container.encode(disabledKeys, forKey: .disabledKeys)
        try container.encode(excludedKeys, forKey: .excludedKeys)
        try container.encode(disabledGlobalHomeRows, forKey: .disabledGlobalHomeRows)
        try container.encode(enabledLibraryHomeRows, forKey: .enabledLibraryHomeRows)
        try container.encode(hasSeededLibraryRows, forKey: .hasSeededLibraryRows)
    }
}

/// A global (cross-server, cross-library) row on Home. The hero is handled
/// separately via `HeroSettings`.
public enum HomeGlobalRow: String, CaseIterable, Sendable {
    case continueWatching
    case watchlist
    case recentlyAdded

    /// The row's display heading (matches ``HomeRowKind`` titles).
    public var title: String {
        switch self {
        case .continueWatching: return "Continue Watching"
        case .watchlist: return "Watchlist"
        case .recentlyAdded: return "Recently Added"
        }
    }
}

/// A per-library row kind that can be opted in to Home in unmerged mode.
///
/// Continue Watching is deliberately **not** here — it's always the single global
/// Continue Watching row (a per-library duplicate is redundant). `hubs` is the
/// provider's native discovery rows (Plex "More in Drama", …); providers without
/// them (Jellyfin) simply contribute nothing for that kind.
public enum LibraryHomeRowKind: String, CaseIterable, Sendable {
    case recentlyAdded
    case hubs

    /// A short label for the Customize Home checklist.
    public var displayName: String {
        switch self {
        case .recentlyAdded: return "Recently Added"
        case .hubs: return "Recommended rows"
        }
    }
}
