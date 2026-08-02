import Foundation

public enum RuntimeFeatureFlag: String, CaseIterable, Codable, Hashable, Sendable {
    case universalWatchlist
}

/// Typed runtime rollout values shared by both application shells. The flag
/// controls exposure and integration only; durable watchlist stores never read
/// it, so disabling the feature cannot erase local state.
public struct RuntimeFeatureFlags: Codable, Hashable, Sendable {
    private var enabled: Set<RuntimeFeatureFlag>

    public init(enabled: Set<RuntimeFeatureFlag> = []) {
        self.enabled = enabled
    }

    public func isEnabled(_ flag: RuntimeFeatureFlag) -> Bool {
        enabled.contains(flag)
    }

    public mutating func set(_ flag: RuntimeFeatureFlag, enabled: Bool) {
        if enabled {
            self.enabled.insert(flag)
        } else {
            self.enabled.remove(flag)
        }
    }

    public static let productionDefault = RuntimeFeatureFlags(
        enabled: [.universalWatchlist]
    )
}
