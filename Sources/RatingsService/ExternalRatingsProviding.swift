import Foundation
import CoreModels

/// A best-effort source of external ratings for a media item.
///
/// Enrichment is intentionally **non-throwing**: a missing API key, absent
/// external id, network failure, or decode error must degrade to an empty
/// array so the detail screen is never blocked or broken by ratings lookups.
public protocol ExternalRatingsProviding: Sendable {
    /// Returns any additional external ratings for `item`, or `[]` when none can
    /// be resolved. Never throws.
    func ratings(for item: MediaItem) async -> [ExternalRating]
}

/// An `ExternalRatingsProviding` that always returns no ratings. Used when no
/// enrichment source is configured (e.g. OMDb API key absent), so callers can
/// always inject a non-optional provider.
public struct DisabledRatingsProvider: ExternalRatingsProviding {
    public init() {}
    public func ratings(for item: MediaItem) async -> [ExternalRating] { [] }
}
