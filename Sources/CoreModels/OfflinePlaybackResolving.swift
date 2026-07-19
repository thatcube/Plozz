import Foundation

/// Leaf seam that lets the playback layer ask "is there a completed offline
/// download for this item, and if so where is its local file?" WITHOUT taking a
/// dependency on the `MediaDownloads` module.
///
/// It lives in `CoreModels` (the graph leaf) on purpose: `FeaturePlayback`
/// already imports `CoreModels`, so injecting a resolver adds **no** new module
/// edge and keeps the layering clean (arch-guard green). The concrete
/// implementation (backed by the download registry) is provided by
/// `MediaDownloads` and wired in at the app layer.
///
/// The contract is deliberately tiny and additive: a `nil` return means "no
/// usable local copy" and the caller must behave exactly as if no resolver were
/// present. Implementations must only return a URL for a **completed** download
/// whose file actually exists on disk.
public protocol OfflinePlaybackResolving: Sendable {
    /// The `file://` URL of a completed, on-disk offline download for `item`, or
    /// `nil` when none exists. Keyed by cross-server ``MediaIdentity`` so a title
    /// downloaded from one server plays offline even when opened from another.
    func localPlaybackURL(for item: MediaItem) async -> URL?
}
