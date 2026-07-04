import Foundation

/// A profile's library **display preferences**: how libraries are laid out on the
/// unified Home screen, which libraries are available at all, and which of the
/// available ones appear on Home.
///
/// Historically this type modelled only the opt-out set of libraries hidden from
/// Home (`excludedKeys`). It now carries the profile's full per-library display
/// state so a single value can be persisted, broadcast, and rebuilt on a profile
/// switch in one place:
///
/// - `mergeLibrariesOnHome` — the all-or-nothing "merge every library's content
///   into unified cross-server rows" switch. `true` (the default) is the classic
///   behaviour; `false` gives each visible library its own section on Home.
/// - `disabledKeys` — libraries the user has turned **off app-wide**. A disabled
///   library is hidden *everywhere* (Home, Search, Music, browse), not just Home.
/// - `excludedKeys` — libraries hidden from **Home only** (still available in
///   Search / Music / browse). This is the original opt-out set, semantics
///   unchanged.
///
/// Library keys are `AggregatedLibrary.key` (`"accountID:libraryID"`).
///
/// ### Predicate vocabulary (read before touching callers)
///
/// Three predicates express the two independent bits so call sites never conflate
/// "available" with "on Home":
/// - ``isEnabled(_:)`` — app-wide availability (`!disabledKeys`).
/// - ``isShownOnHome(_:)`` — the Home-only bit the Settings "Show on Home" toggle
///   reads/writes (`!excludedKeys`); independent of enabled so re-enabling a
///   library restores its previous Home choice.
/// - ``isVisibleOnHome(_:)`` — what Home *rendering* and aggregation use: enabled
///   **and** shown. ``isVisible(_:)`` is a compatibility alias for this so the
///   existing render/hero/Top-Shelf call sites keep their meaning.
public struct HomeLibraryVisibility: Codable, Equatable, Sendable {
    /// Whether Home merges every library's content into unified cross-server rows
    /// (`true`, the classic behaviour) or gives each visible library its own
    /// section (`false`).
    public var mergeLibrariesOnHome: Bool

    /// Keys of libraries the user has turned off **app-wide** — hidden from Home,
    /// Search, Music and browse alike.
    public var disabledKeys: Set<String>

    /// Keys of libraries hidden from **Home only**. Still available everywhere
    /// else. (The original opt-out set; name kept to avoid a wide rename.)
    public var excludedKeys: Set<String>

    public init(
        mergeLibrariesOnHome: Bool = true,
        disabledKeys: Set<String> = [],
        excludedKeys: Set<String> = []
    ) {
        self.mergeLibrariesOnHome = mergeLibrariesOnHome
        self.disabledKeys = disabledKeys
        self.excludedKeys = excludedKeys
    }

    /// The default: merge on, nothing disabled, nothing hidden — every library is
    /// available and visible on a single merged Home, matching pre-customization
    /// behaviour.
    public static let `default` = HomeLibraryVisibility()

    // MARK: - Predicates

    /// Whether the library with `key` is available **app-wide** (not disabled).
    /// A disabled library is hidden everywhere: Home, Search, Music and browse.
    public func isEnabled(_ key: String) -> Bool {
        !disabledKeys.contains(key)
    }

    /// The Home-only visibility bit — whether the user has kept this library on
    /// Home, *ignoring* whether it's enabled. This is what the Settings
    /// "Show on Home" toggle reflects, so toggling it while a library is disabled
    /// (or re-enabling later) preserves the user's Home choice.
    public func isShownOnHome(_ key: String) -> Bool {
        !excludedKeys.contains(key)
    }

    /// Whether the library actually appears on Home: it must be both enabled
    /// (available app-wide) **and** shown on Home. Used by Home rendering and the
    /// aggregator's visible-library scoping.
    public func isVisibleOnHome(_ key: String) -> Bool {
        isEnabled(key) && isShownOnHome(key)
    }

    /// Compatibility alias for ``isVisibleOnHome(_:)`` for the render/hero/Top-Shelf
    /// call sites that previously asked "is this library visible on Home?".
    public func isVisible(_ key: String) -> Bool {
        isVisibleOnHome(key)
    }

    // MARK: - Mutation

    /// Turns a library on/off **app-wide**. Disabling hides it everywhere; the
    /// separate Home-only choice (`excludedKeys`) is left untouched so re-enabling
    /// restores it.
    public mutating func setEnabled(_ enabled: Bool, for key: String) {
        if enabled {
            disabledKeys.remove(key)
        } else {
            disabledKeys.insert(key)
        }
    }

    /// Sets whether a library is shown on **Home only** (the original opt-out).
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

    // MARK: - Codable (backward compatible)

    private enum CodingKeys: String, CodingKey {
        case mergeLibrariesOnHome
        case disabledKeys
        case excludedKeys
    }

    /// Decodes leniently so a pre-existing blob written when this type held only
    /// `excludedKeys` still loads: the missing `mergeLibrariesOnHome` falls back to
    /// `true` (classic merged Home) and `disabledKeys` to empty, so an upgrading
    /// install sees zero Home behaviour change until it opts in.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.mergeLibrariesOnHome = try container.decodeIfPresent(Bool.self, forKey: .mergeLibrariesOnHome) ?? true
        self.disabledKeys = try container.decodeIfPresent(Set<String>.self, forKey: .disabledKeys) ?? []
        self.excludedKeys = try container.decodeIfPresent(Set<String>.self, forKey: .excludedKeys) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mergeLibrariesOnHome, forKey: .mergeLibrariesOnHome)
        try container.encode(disabledKeys, forKey: .disabledKeys)
        try container.encode(excludedKeys, forKey: .excludedKeys)
    }
}
