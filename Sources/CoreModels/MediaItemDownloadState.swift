import Foundation

/// An item's offline-download state as the ACTION CATALOG needs it.
///
/// Deliberately coarse and provider-agnostic: the catalog only has to choose
/// between start / pause / resume / remove, so it needs the four buckets and not
/// a byte count. Keeping it here (rather than importing `MediaDownloads`) keeps
/// `MediaItemActionCatalog` free of the download stack and unit-testable on
/// Linux, matching how the rest of the catalog's capabilities are expressed.
public enum MediaItemDownloadState: Equatable, Sendable {
    /// Queued or actively transferring.
    case inFlight
    /// Paused or failed — resumable.
    case interrupted
    /// Complete and playable offline.
    case downloaded
}
