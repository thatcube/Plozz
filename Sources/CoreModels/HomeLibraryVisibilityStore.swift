import Foundation
import Observation

/// Persists `HomeLibraryVisibility` across launches.
public protocol HomeLibraryVisibilityStoring: Sendable {
    func load() -> HomeLibraryVisibility
    func save(_ visibility: HomeLibraryVisibility)
}

public final class HomeLibraryVisibilityStore: HomeLibraryVisibilityStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    /// - Parameter namespace: per-profile scope. `nil` (the default/primary
    ///   profile) uses the legacy un-suffixed key so upgrading installs keep
    ///   their Home customization; other profiles pass their `Profile.id` so each
    ///   profile gets its own independent set of hidden libraries.
    public init(defaults: UserDefaults = .standard, namespace: String? = nil) {
        self.defaults = defaults
        self.key = SettingsKey.scoped("com.plozz.homeLibraryVisibility", namespace: namespace)
    }

    public func load() -> HomeLibraryVisibility {
        guard let data = defaults.data(forKey: key),
              let visibility = try? JSONDecoder().decode(HomeLibraryVisibility.self, from: data) else {
            return .default
        }
        return visibility
    }

    public func save(_ visibility: HomeLibraryVisibility) {
        if let data = try? JSONEncoder().encode(visibility) {
            defaults.set(data, forKey: key)
        }
    }
}

/// Observable wrapper so the Settings checklist can two-way bind the per-library
/// toggles (enabled + show-on-home) and the merge switch, and have each choice
/// persisted immediately + broadcast to Home / Search / Music.
@MainActor
@Observable
public final class HomeLibraryVisibilityModel {
    public private(set) var visibility: HomeLibraryVisibility

    private let store: HomeLibraryVisibilityStoring

    public init(store: HomeLibraryVisibilityStoring = HomeLibraryVisibilityStore()) {
        self.store = store
        self.visibility = store.load()
    }

    // MARK: - Merge

    /// Whether Home merges every library into unified cross-server rows.
    public var mergeLibrariesOnHome: Bool {
        visibility.mergeLibrariesOnHome
    }

    /// Sets the all-or-nothing "merge libraries on Home" switch and persists.
    public func setMergeLibrariesOnHome(_ merge: Bool) {
        guard visibility.mergeLibrariesOnHome != merge else { return }
        visibility.mergeLibrariesOnHome = merge
        store.save(visibility)
    }

    // MARK: - Global Home rows

    /// Whether a global Home row (Continue Watching / Watchlist / Recently Added)
    /// is shown (default on).
    public func isGlobalRowEnabled(_ row: HomeGlobalRow) -> Bool {
        visibility.isGlobalRowEnabled(row)
    }

    /// Shows/hides a global Home row and persists.
    public func setGlobalRowEnabled(_ enabled: Bool, for row: HomeGlobalRow) {
        visibility.setGlobalRowEnabled(enabled, for: row)
        store.save(visibility)
    }

    // MARK: - Per-library Home rows (unmerged, opt-in)

    /// Whether a per-library row is opted in to Home (default off).
    public func isLibraryRowEnabled(_ libraryKey: String, kind: LibraryHomeRowKind) -> Bool {
        visibility.isLibraryRowEnabled(libraryKey, kind: kind)
    }

    /// Opts a per-library row in/out of Home and persists.
    public func setLibraryRowEnabled(_ enabled: Bool, libraryKey: String, kind: LibraryHomeRowKind) {
        visibility.setLibraryRowEnabled(enabled, libraryKey: libraryKey, kind: kind)
        store.save(visibility)
    }

    /// Seeds all provided per-library rows **on** the first time the user
    /// unmerges, then persists. Called when the merge switch is turned **off** so
    /// the unmerged Home starts populated rather than empty (see
    /// ``HomeLibraryVisibility/seedLibraryRowsIfNeeded(_:)``). A no-op once the
    /// one-time seeding has run, so it never re-seeds over the user's row choices.
    public func seedLibraryRowsIfNeeded(_ rows: [(libraryKey: String, kind: LibraryHomeRowKind)]) {
        if visibility.seedLibraryRowsIfNeeded(rows) {
            store.save(visibility)
        }
    }

    // MARK: - Per-library predicates

    /// Whether the library is on (not disabled).
    public func isEnabled(_ key: String) -> Bool {
        visibility.isEnabled(key)
    }

    /// Whether the library appears on Home (now just ``isEnabled(_:)`` — the
    /// separate Home-only opt-out was retired).
    public func isVisibleOnHome(_ key: String) -> Bool {
        visibility.isVisibleOnHome(key)
    }

    /// Compatibility alias for ``isVisibleOnHome(_:)``.
    public func isVisible(_ key: String) -> Bool {
        visibility.isVisible(key)
    }

    // MARK: - Per-library mutation

    /// Turns a library on/off and persists immediately.
    public func setEnabled(_ enabled: Bool, for key: String) {
        visibility.setEnabled(enabled, for: key)
        store.save(visibility)
    }
}
