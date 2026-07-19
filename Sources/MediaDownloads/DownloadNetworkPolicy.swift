import Foundation

/// Observed network conditions the download gate reasons about.
public struct DownloadNetworkConditions: Sendable, Equatable {
    /// A usable path exists at all.
    public var isSatisfied: Bool
    /// The path is expensive (cellular, personal hotspot) — `NWPath.isExpensive`.
    public var isExpensive: Bool
    /// The path is in Low Data / constrained mode — `NWPath.isConstrained`.
    public var isConstrained: Bool

    public init(isSatisfied: Bool, isExpensive: Bool, isConstrained: Bool) {
        self.isSatisfied = isSatisfied
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
    }

    /// Optimistic default used before the first real observation.
    public static let unknownSatisfied = DownloadNetworkConditions(
        isSatisfied: true, isExpensive: false, isConstrained: false
    )
    public static let unsatisfied = DownloadNetworkConditions(
        isSatisfied: false, isExpensive: false, isConstrained: false
    )
}

/// Per-profile, data-driven download policy. Ships a sensible default (Wi‑Fi‑only,
/// original quality) but every knob is a value flip so the future UI / settings
/// can change it without touching the engine.
public struct DownloadNetworkPolicy: Sendable, Equatable, Codable {
    /// Allow downloading over cellular/expensive paths. Default `false` = the
    /// familiar "Download over Wi‑Fi only" behavior.
    public var allowsExpensiveNetwork: Bool
    /// Pause when the path is constrained (iOS Low Data Mode). Default `true`.
    public var pausesOnConstrainedNetwork: Bool
    /// Preferred rendition. `.dataSaver` requests a smaller transcoded copy from
    /// managed providers (ignored for direct shares, which have only the original).
    public var quality: DownloadQuality
    /// Soft storage budget in bytes; when exceeded, NEW downloads are blocked
    /// (completed/pinned media is never auto-evicted). `nil` = unlimited.
    public var storageBudgetBytes: Int64?
    /// Max downloads running at once.
    public var maxConcurrentDownloads: Int

    public init(
        allowsExpensiveNetwork: Bool = false,
        pausesOnConstrainedNetwork: Bool = true,
        quality: DownloadQuality = .original,
        storageBudgetBytes: Int64? = nil,
        maxConcurrentDownloads: Int = 1
    ) {
        self.allowsExpensiveNetwork = allowsExpensiveNetwork
        self.pausesOnConstrainedNetwork = pausesOnConstrainedNetwork
        self.quality = quality
        self.storageBudgetBytes = storageBudgetBytes
        self.maxConcurrentDownloads = max(1, maxConcurrentDownloads)
    }

    public static let `default` = DownloadNetworkPolicy()

    /// Whether downloading may proceed under the given conditions.
    public func allows(_ conditions: DownloadNetworkConditions) -> Bool {
        guard conditions.isSatisfied else { return false }
        if conditions.isExpensive, !allowsExpensiveNetwork { return false }
        if conditions.isConstrained, pausesOnConstrainedNetwork { return false }
        return true
    }
}

/// Seam for observing current network conditions, so the queue and tests can be
/// driven deterministically.
public protocol DownloadNetworkObserving: Sendable {
    func currentConditions() async -> DownloadNetworkConditions
}

/// A fixed-conditions observer for tests/previews.
public struct StaticDownloadNetworkObserver: DownloadNetworkObserving {
    private let conditions: DownloadNetworkConditions
    public init(_ conditions: DownloadNetworkConditions = .unknownSatisfied) {
        self.conditions = conditions
    }
    public func currentConditions() async -> DownloadNetworkConditions { conditions }
}
