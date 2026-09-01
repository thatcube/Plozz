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
    /// Aggregate offline-download cap in bytes/sec. `nil` means unlimited.
    public var maximumBytesPerSecond: Int64?
    /// What capped managed downloads do when iOS suspends the app.
    public var cappedBackgroundBehavior: CappedDownloadBackgroundBehavior
    /// Preserve every alternate audio rendition when the server exposes them.
    public var includesAllAudioTracks: Bool
    /// Preserve downloadable text-subtitle renditions for constrained copies.
    public var includesTextSubtitleTracks: Bool

    public init(
        allowsExpensiveNetwork: Bool = false,
        pausesOnConstrainedNetwork: Bool = true,
        quality: DownloadQuality = .original,
        storageBudgetBytes: Int64? = nil,
        maxConcurrentDownloads: Int = 1,
        maximumBytesPerSecond: Int64? = nil,
        cappedBackgroundBehavior: CappedDownloadBackgroundBehavior = .pause,
        includesAllAudioTracks: Bool = false,
        includesTextSubtitleTracks: Bool = true
    ) {
        self.allowsExpensiveNetwork = allowsExpensiveNetwork
        self.pausesOnConstrainedNetwork = pausesOnConstrainedNetwork
        self.quality = quality
        self.storageBudgetBytes = storageBudgetBytes
        self.maxConcurrentDownloads = max(1, maxConcurrentDownloads)
        self.maximumBytesPerSecond = maximumBytesPerSecond.flatMap {
            $0 > 0 ? $0 : nil
        }
        self.cappedBackgroundBehavior = cappedBackgroundBehavior
        self.includesAllAudioTracks = includesAllAudioTracks
        self.includesTextSubtitleTracks = includesTextSubtitleTracks
    }

    public static let `default` = DownloadNetworkPolicy()

    /// Whether downloading may proceed under the given conditions.
    public func allows(_ conditions: DownloadNetworkConditions) -> Bool {
        guard conditions.isSatisfied else { return false }
        if conditions.isExpensive, !allowsExpensiveNetwork { return false }
        if conditions.isConstrained, pausesOnConstrainedNetwork { return false }
        return true
    }

    private enum CodingKeys: String, CodingKey {
        case allowsExpensiveNetwork
        case pausesOnConstrainedNetwork
        case quality
        case storageBudgetBytes
        case maxConcurrentDownloads
        case maximumBytesPerSecond
        case cappedBackgroundBehavior
        case includesAllAudioTracks
        case includesTextSubtitleTracks
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            allowsExpensiveNetwork: try container.decodeIfPresent(
                Bool.self,
                forKey: .allowsExpensiveNetwork
            ) ?? false,
            pausesOnConstrainedNetwork: try container.decodeIfPresent(
                Bool.self,
                forKey: .pausesOnConstrainedNetwork
            ) ?? true,
            quality: try container.decodeIfPresent(
                DownloadQuality.self,
                forKey: .quality
            ) ?? .original,
            storageBudgetBytes: try container.decodeIfPresent(
                Int64.self,
                forKey: .storageBudgetBytes
            ),
            maxConcurrentDownloads: try container.decodeIfPresent(
                Int.self,
                forKey: .maxConcurrentDownloads
            ) ?? 1,
            maximumBytesPerSecond: try container.decodeIfPresent(
                Int64.self,
                forKey: .maximumBytesPerSecond
            ),
            cappedBackgroundBehavior: try container.decodeIfPresent(
                CappedDownloadBackgroundBehavior.self,
                forKey: .cappedBackgroundBehavior
            ) ?? .pause,
            includesAllAudioTracks: try container.decodeIfPresent(
                Bool.self,
                forKey: .includesAllAudioTracks
            ) ?? false,
            includesTextSubtitleTracks: try container.decodeIfPresent(
                Bool.self,
                forKey: .includesTextSubtitleTracks
            ) ?? true
        )
    }
}

public enum CappedDownloadBackgroundBehavior: String, Codable, Sendable, Hashable {
    case pause
    case continueAtFullSpeed
}

/// Seam for observing current network conditions, so the queue and tests can be
/// driven deterministically.
public protocol DownloadNetworkObserving: Sendable {
    func currentConditions() async -> DownloadNetworkConditions
    func updates() -> AsyncStream<DownloadNetworkConditions>
}

public extension DownloadNetworkObserving {
    func updates() -> AsyncStream<DownloadNetworkConditions> {
        AsyncStream { $0.finish() }
    }
}

/// A fixed-conditions observer for tests/previews.
public struct StaticDownloadNetworkObserver: DownloadNetworkObserving {
    private let conditions: DownloadNetworkConditions
    public init(_ conditions: DownloadNetworkConditions = .unknownSatisfied) {
        self.conditions = conditions
    }
    public func currentConditions() async -> DownloadNetworkConditions { conditions }
}
