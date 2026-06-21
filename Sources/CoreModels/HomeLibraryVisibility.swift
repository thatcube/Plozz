import Foundation

/// The user's choice of which libraries appear on the unified Home screen.
///
/// Stores the set of **excluded** library keys (see `AggregatedLibrary.key`).
/// Semantics are **opt-out**: any library whose key is not in `excludedKeys` is
/// visible, so newly discovered libraries appear on Home automatically and the
/// default (empty) value matches the pre-customization behaviour of showing
/// every library.
public struct HomeLibraryVisibility: Codable, Equatable, Sendable {
    /// Keys of libraries the user has explicitly hidden from Home.
    public var excludedKeys: Set<String>

    public init(excludedKeys: Set<String> = []) {
        self.excludedKeys = excludedKeys
    }

    /// The default: nothing excluded — every library is visible.
    public static let `default` = HomeLibraryVisibility()

    /// Whether the library with `key` should appear on Home.
    public func isVisible(_ key: String) -> Bool {
        !excludedKeys.contains(key)
    }

    /// Sets the Home visibility of the library with `key`.
    public mutating func setVisible(_ visible: Bool, for key: String) {
        if visible {
            excludedKeys.remove(key)
        } else {
            excludedKeys.insert(key)
        }
    }
}
