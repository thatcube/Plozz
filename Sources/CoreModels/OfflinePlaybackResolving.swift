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
    /// The `file://` URL of a completed, on-disk offline download of a
    /// **specific version** of `item`, or `nil` when that version isn't
    /// downloaded. Keyed by cross-server ``MediaIdentity`` so a title downloaded
    /// from one server plays offline even when opened from another.
    ///
    /// The version must be honoured: a title can have a 4K and a 1080p file, and
    /// only one of them may be on disk. Ignoring it makes every version the user
    /// picks play whichever copy was downloaded — silently, since playback
    /// "works", just not with the file they chose.
    ///
    /// `nil` `versionID` means "no particular version", which matches any
    /// downloaded copy (used by callers that only ask "is this available
    /// offline?").
    func localPlaybackURL(for item: MediaItem, versionID: String?) async -> URL?
}

public extension OfflinePlaybackResolving {
    /// Version-agnostic convenience for availability checks.
    func localPlaybackURL(for item: MediaItem) async -> URL? {
        await localPlaybackURL(for: item, versionID: nil)
    }
}
