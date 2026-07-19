import CoreModels
import Foundation

/// The durable record for one downloaded (or downloading) item.
///
/// Written **before** the first byte is fetched (with `.downloading`/`.queued`),
/// so a hard kill always leaves a recoverable, resumable record — the download
/// registry's idempotency guarantee.
public struct DownloadedMediaRecord: Codable, Sendable, Hashable, Identifiable {
    /// Stable ``MediaIdentity`` key (see ``MediaIdentityKey``). Primary id and the
    /// name of the on-disk folder.
    public var identityKey: String
    /// The cross-server identity this download satisfies.
    public var identity: MediaIdentity
    /// Optional grouping (e.g. a whole season enqueued together).
    public var groupID: String?

    public var sourceKind: DownloadSourceKind
    public var quality: DownloadQuality
    public var status: DownloadStatus

    /// Direct-share reopen info (present when `sourceKind == .directShare`).
    public var directShareSource: DirectShareDownloadSource?

    /// Leaf filename of the pinned media file inside the download's folder
    /// (e.g. `media.mkv`).
    public var localFileName: String
    public var bytesDownloaded: Int64
    public var totalBytes: Int64?
    public var contentType: String?
    /// Human-readable reason for a `.failed`/`.paused` state (never secret).
    public var failureReason: String?

    /// Pinned, offline-renderable metadata (title/kind/year/artwork filename).
    public var snapshot: PinnedMediaSnapshot

    public var createdAt: Date
    public var updatedAt: Date

    public var id: String { identityKey }

    public init(
        identity: MediaIdentity,
        groupID: String? = nil,
        sourceKind: DownloadSourceKind,
        quality: DownloadQuality = .original,
        status: DownloadStatus = .queued,
        directShareSource: DirectShareDownloadSource? = nil,
        localFileName: String,
        bytesDownloaded: Int64 = 0,
        totalBytes: Int64? = nil,
        contentType: String? = nil,
        failureReason: String? = nil,
        snapshot: PinnedMediaSnapshot,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.identityKey = MediaIdentityKey.string(for: identity)
        self.identity = identity
        self.groupID = groupID
        self.sourceKind = sourceKind
        self.quality = quality
        self.status = status
        self.directShareSource = directShareSource
        self.localFileName = localFileName
        self.bytesDownloaded = bytesDownloaded
        self.totalBytes = totalBytes
        self.contentType = contentType
        self.failureReason = failureReason
        self.snapshot = snapshot
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Fractional progress in `0...1`, or `nil` when the total size is unknown.
    public var fractionCompleted: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, Double(bytesDownloaded) / Double(totalBytes))
    }
}

/// The full persisted download catalog for one profile: every record keyed by its
/// identity key. Plain `Codable` value data so a fresh install starts from a
/// well-defined **empty** state.
public struct DownloadedMediaRegistryState: Codable, Sendable, Equatable {
    public var records: [String: DownloadedMediaRecord]

    public init(records: [String: DownloadedMediaRecord] = [:]) {
        self.records = records
    }

    public static let empty = DownloadedMediaRegistryState()
}

extension DownloadedMediaRegistryState: DurableLocalStateValue {
    public static let durableLocalStateSchemaID = "com.plozz.media-downloads.v1"
}
