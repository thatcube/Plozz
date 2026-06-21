import Foundation
import Observation

/// Persists `HomeLibraryVisibility` across launches.
public protocol HomeLibraryVisibilityStoring: Sendable {
    func load() -> HomeLibraryVisibility
    func save(_ visibility: HomeLibraryVisibility)
}

public final class HomeLibraryVisibilityStore: HomeLibraryVisibilityStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "com.plozz.homeLibraryVisibility"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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

/// Observable wrapper so the Settings checklist can two-way bind a per-library
/// toggle and have the choice persisted + broadcast to Home.
@MainActor
@Observable
public final class HomeLibraryVisibilityModel {
    public private(set) var visibility: HomeLibraryVisibility

    private let store: HomeLibraryVisibilityStoring

    public init(store: HomeLibraryVisibilityStoring = HomeLibraryVisibilityStore()) {
        self.store = store
        self.visibility = store.load()
    }

    /// Whether the library with `key` is shown on Home (opt-out default).
    public func isVisible(_ key: String) -> Bool {
        visibility.isVisible(key)
    }

    /// Toggles a library's Home visibility and persists immediately.
    public func setVisible(_ visible: Bool, for key: String) {
        visibility.setVisible(visible, for: key)
        store.save(visibility)
    }
}
