import CoreModels
import Foundation

/// A live update emitted by the registry as downloads change. Future UI binds a
/// per-item progress bar, a per-group aggregate, and a global indicator to this
/// one stream.
public enum DownloadProgressEvent: Sendable, Equatable {
    /// A single record changed (progress tick or status transition).
    case item(DownloadedMediaRecord)
    /// A record was removed from the catalog.
    case removed(identityKey: String)
    /// Aggregate progress for a group (season) — Σ bytes over Σ totals.
    case group(GroupProgress)
    /// Global aggregate across all active downloads.
    case global(GlobalProgress)

    public struct GroupProgress: Sendable, Equatable {
        public var groupID: String
        public var totalItems: Int
        public var completedItems: Int
        public var bytesDownloaded: Int64
        public var totalBytes: Int64?

        public init(
            groupID: String,
            totalItems: Int,
            completedItems: Int,
            bytesDownloaded: Int64,
            totalBytes: Int64?
        ) {
            self.groupID = groupID
            self.totalItems = totalItems
            self.completedItems = completedItems
            self.bytesDownloaded = bytesDownloaded
            self.totalBytes = totalBytes
        }

        public var fractionCompleted: Double? {
            guard let totalBytes, totalBytes > 0 else { return nil }
            return min(1, Double(bytesDownloaded) / Double(totalBytes))
        }
    }

    public struct GlobalProgress: Sendable, Equatable {
        public var activeItems: Int
        public var bytesDownloaded: Int64
        public var totalBytes: Int64?

        public init(activeItems: Int, bytesDownloaded: Int64, totalBytes: Int64?) {
            self.activeItems = activeItems
            self.bytesDownloaded = bytesDownloaded
            self.totalBytes = totalBytes
        }

        public var fractionCompleted: Double? {
            guard let totalBytes, totalBytes > 0 else { return nil }
            return min(1, Double(bytesDownloaded) / Double(totalBytes))
        }
    }
}
