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

/// Provider-neutral rendition intent. Managed providers translate constrained
/// qualities into their native offline-transcode request; direct shares support
/// only ``original``.
public enum DownloadQuality: Codable, Sendable, Hashable {
    case original
    case constrained(DownloadRenditionConstraint)

    public static let hd1080 = DownloadQuality.constrained(
        .init(maximumHeight: 1_080, maximumVideoBitrateBps: 20_000_000)
    )
    public static let hd720 = DownloadQuality.constrained(
        .init(maximumHeight: 720, maximumVideoBitrateBps: 4_000_000)
    )
    public static let sd480 = DownloadQuality.constrained(
        .init(maximumHeight: 480, maximumVideoBitrateBps: 1_500_000)
    )

    private enum CodingKeys: String, CodingKey {
        case kind
        case constraint
    }

    private enum Kind: String, Codable {
        case original
        case constrained
    }

    public init(from decoder: any Decoder) throws {
        // v1 stored a single string. Preserve original and map the never-wired
        // data-saver placeholder onto the agreed 480p preset.
        if let legacy = try? decoder.singleValueContainer().decode(String.self) {
            self = legacy == "dataSaver" ? .sd480 : .original
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .original:
            self = .original
        case .constrained:
            self = .constrained(
                try container.decode(
                    DownloadRenditionConstraint.self,
                    forKey: .constraint
                )
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .original:
            try container.encode(Kind.original, forKey: .kind)
        case .constrained(let constraint):
            try container.encode(Kind.constrained, forKey: .kind)
            try container.encode(constraint, forKey: .constraint)
        }
    }
}

public struct DownloadRenditionConstraint: Codable, Sendable, Hashable {
    public var maximumHeight: Int
    public var maximumVideoBitrateBps: Int

    public init(maximumHeight: Int, maximumVideoBitrateBps: Int) {
        self.maximumHeight = max(144, maximumHeight)
        self.maximumVideoBitrateBps = max(500_000, maximumVideoBitrateBps)
    }
}

public enum DownloadPauseReason: String, Codable, Sendable, Hashable {
    case manual
    case networkPolicy
    case backgroundPolicy
    case directShareBackground
}

public enum DownloadBatchKind: String, Codable, Sendable, Hashable {
    case season
    case show
}

/// The lifecycle of a single downloaded item.
public enum DownloadStatus: String, Codable, Sendable, Hashable {
    /// Enqueued, no bytes fetched yet.
    case queued
    /// The server is preparing a reduced offline rendition.
    case preparing
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
        case .queued, .preparing, .downloading: return true
        case .paused, .failed, .completed: return false
        }
    }
}
