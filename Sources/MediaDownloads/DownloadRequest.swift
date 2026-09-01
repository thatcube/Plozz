import CoreModels
import Foundation

/// A request to download one item. The caller (a provider/UI layer) supplies the
/// cross-server identity, the transport source, and a pinned metadata snapshot;
/// the queue owns everything after that.
public struct DownloadRequest: Sendable {
    public var identity: MediaIdentity
    /// The specific version (file) being downloaded, so two versions of one
    /// title are stored as separate records rather than one overwriting the
    /// other. See ``MediaIdentityKey/string(for:versionID:)``.
    public var versionID: String?
    /// Pinned human-readable version label for the downloads list.
    public var versionLabel: String?
    public var groupID: String?
    public var batchID: String?
    public var batchKind: DownloadBatchKind?
    public var batchTitle: String?
    public var batchExpectedCount: Int?
    public var expectedBytes: Int64?
    public var sourceKind: DownloadSourceKind
    public var quality: DownloadQuality
    public var directShareSource: DirectShareDownloadSource?
    public var managedHTTPSource: ManagedHTTPDownloadSource?
    public var contentType: String?
    /// Explicit media file extension (e.g. `mkv`); when nil, derived from the
    /// source path or content type.
    public var fileExtension: String?
    public var snapshot: PinnedMediaSnapshot

    public init(
        identity: MediaIdentity,
        versionID: String? = nil,
        versionLabel: String? = nil,
        groupID: String? = nil,
        batchID: String? = nil,
        batchKind: DownloadBatchKind? = nil,
        batchTitle: String? = nil,
        batchExpectedCount: Int? = nil,
        expectedBytes: Int64? = nil,
        sourceKind: DownloadSourceKind,
        quality: DownloadQuality = .original,
        directShareSource: DirectShareDownloadSource? = nil,
        managedHTTPSource: ManagedHTTPDownloadSource? = nil,
        contentType: String? = nil,
        fileExtension: String? = nil,
        snapshot: PinnedMediaSnapshot
    ) {
        self.identity = identity
        self.versionID = versionID
        self.versionLabel = versionLabel
        self.groupID = groupID
        self.batchID = batchID
        self.batchKind = batchKind
        self.batchTitle = batchTitle
        self.batchExpectedCount = batchExpectedCount
        self.expectedBytes = expectedBytes
        self.sourceKind = sourceKind
        self.quality = quality
        self.directShareSource = directShareSource
        self.managedHTTPSource = managedHTTPSource
        self.contentType = contentType
        self.fileExtension = fileExtension
        self.snapshot = snapshot
    }

    public static func managedHTTP(
        identity: MediaIdentity,
        source: ManagedHTTPDownloadSource,
        snapshot: PinnedMediaSnapshot,
        versionID: String? = nil,
        versionLabel: String? = nil,
        groupID: String? = nil,
        batchID: String? = nil,
        batchKind: DownloadBatchKind? = nil,
        batchTitle: String? = nil,
        batchExpectedCount: Int? = nil,
        expectedBytes: Int64? = nil,
        contentType: String? = nil,
        fileExtension: String? = nil,
        quality: DownloadQuality = .original
    ) -> DownloadRequest {
        DownloadRequest(
            identity: identity,
            versionID: versionID,
            versionLabel: versionLabel,
            groupID: groupID,
            batchID: batchID,
            batchKind: batchKind,
            batchTitle: batchTitle,
            batchExpectedCount: batchExpectedCount,
            expectedBytes: expectedBytes,
            sourceKind: .managedHTTP,
            quality: quality,
            managedHTTPSource: source,
            contentType: contentType,
            fileExtension: fileExtension,
            snapshot: snapshot
        )
    }

    /// Convenience for a direct-share download built from a fully-formed locator.
    public static func directShare(
        identity: MediaIdentity,
        locator: NetworkFileLocator,
        snapshot: PinnedMediaSnapshot,
        versionID: String? = nil,
        versionLabel: String? = nil,
        groupID: String? = nil,
        batchID: String? = nil,
        batchKind: DownloadBatchKind? = nil,
        batchTitle: String? = nil,
        batchExpectedCount: Int? = nil,
        expectedBytes: Int64? = nil,
        contentType: String? = nil,
        container: String? = nil,
        quality: DownloadQuality = .original
    ) -> DownloadRequest {
        DownloadRequest(
            identity: identity,
            versionID: versionID,
            versionLabel: versionLabel,
            groupID: groupID,
            batchID: batchID,
            batchKind: batchKind,
            batchTitle: batchTitle,
            batchExpectedCount: batchExpectedCount,
            expectedBytes: expectedBytes,
            sourceKind: .directShare,
            quality: quality,
            directShareSource: DirectShareDownloadSource(
                locator: locator,
                container: container,
                mimeType: contentType
            ),
            contentType: contentType,
            fileExtension: container ?? (locator.relativePath as NSString).pathExtension,
            snapshot: snapshot
        )
    }

    func makeLocalFileName() -> String {
        let ext = (fileExtension?.isEmpty == false ? fileExtension : nil)
            ?? directShareSource.map { ($0.relativePath as NSString).pathExtension }
            ?? ""
        return ext.isEmpty ? "media" : "media.\(ext)"
    }
}
