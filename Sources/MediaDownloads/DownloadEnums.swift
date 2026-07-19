import CoreModels
import Foundation

/// Which transport family a download is served over. Determines the engine that
/// fetches the bytes and whether the OS can continue the transfer while the app
/// is suspended.
public enum DownloadSourceKind: String, Codable, Sendable, Hashable {
    /// Direct network share (SMB/NFS/WebDAV/SFTP/FTP): read via the transport
    /// cursor byte API. Foreground/while-running only; resumes by byte offset.
    case directShare
    /// Managed provider (Jellyfin/Emby/Plex) over HTTP: eligible for a background
    /// `URLSession` transfer that survives suspension. (Engine lands in a later
    /// phase; the record already models it so no migration is needed.)
    case managedHTTP
}

/// The quality/rendition a download was captured at. "Data saver" downloads a
/// smaller transcoded rendition — only possible on managed providers, since a
/// direct share exposes only the original file.
public enum DownloadQuality: String, Codable, Sendable, Hashable {
    case original
    case dataSaver
}

/// The lifecycle of a single downloaded item.
public enum DownloadStatus: String, Codable, Sendable, Hashable {
    /// Enqueued, no bytes fetched yet.
    case queued
    /// Actively fetching bytes.
    case downloading
    /// Interrupted with a recoverable partial file (user pause, cancellation,
    /// or a network gate closing). Resumable from `bytesDownloaded`.
    case paused
    /// Failed with a fatal (non-retryable) error; needs user action.
    case failed
    /// Fully downloaded and pinned; the local file is playable offline.
    case completed

    /// Whether more bytes are expected for this item (it belongs in the active
    /// drain set).
    public var isActive: Bool {
        switch self {
        case .queued, .downloading, .paused: return true
        case .failed, .completed: return false
        }
    }
}
