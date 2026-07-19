import Foundation

/// The reason a credential-free network artwork reference could not produce a
/// usable still image. The reference is included only as a value passed back to
/// the catalog owner; callers must not log its path or transport representation.
public enum ArtworkNetworkFileFailure: String, Codable, Sendable, Equatable {
    case unavailable
    case empty
    case tooLarge
    case malformed
    case unsupported
    case unsafeDimensions
    case cancelled
}

/// Transport-neutral terminal loading error. Adapters use this instead of leaking
/// a transport-specific error type into CoreUI.
public struct ArtworkNetworkFileLoadError: Error, Sendable, Equatable {
    public let failure: ArtworkNetworkFileFailure

    public init(_ failure: ArtworkNetworkFileFailure) {
        self.failure = failure
    }
}

/// Narrow composition-boundary interface for loading direct-share artwork.
///
/// `CoreUI` depends on this protocol rather than `MediaTransportCore`. Remote URL
/// references deliberately do not go through this interface; they remain owned by
/// `ArtworkSession` and its HTTP cache.
public protocol ArtworkNetworkFileLoading: Sendable {
    /// Returns at most `maximumBytes` compressed bytes for `reference`.
    func loadArtwork(
        _ reference: NetworkArtworkReference,
        maximumBytes: Int
    ) async throws -> Data
}

/// Receives terminal display-time failures for the exact local-artwork
/// fingerprint. Implementations can invalidate that candidate without exposing
/// paths, credentials, or signed URLs to UI code.
public protocol ArtworkNetworkFileFailureReporting: Sendable {
    func reportArtworkFailure(
        _ failure: ArtworkNetworkFileFailure,
        for reference: NetworkArtworkReference
    ) async
}

/// Composition value used by CoreUI for local artwork. Keeping the loader and
/// reporter together prevents a UI component from accidentally observing or
/// carrying transport credentials.
public struct ArtworkNetworkFileService: Sendable {
    public let loader: any ArtworkNetworkFileLoading
    public let failureReporter: (any ArtworkNetworkFileFailureReporting)?

    public init(
        loader: any ArtworkNetworkFileLoading,
        failureReporter: (any ArtworkNetworkFileFailureReporting)? = nil
    ) {
        self.loader = loader
        self.failureReporter = failureReporter
    }
}
