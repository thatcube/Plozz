import CoreModels
import Foundation

/// Everything needed to (re)open a direct-share file for download, persisted so a
/// download can resume after a relaunch or a hard kill.
///
/// It is `Codable` value data (unlike ``NetworkFileLocator``, which has a
/// validating initializer); ``makeLocator()`` rebuilds the validated locator on
/// demand.
public struct DirectShareDownloadSource: Codable, Sendable, Hashable {
    public var accountID: String
    public var sourceID: String
    public var credentialRevision: CredentialRevision
    public var relativePath: String
    public var representation: RemoteFileRepresentation
    public var container: String?
    public var mimeType: String?

    public init(
        accountID: String,
        sourceID: String,
        credentialRevision: CredentialRevision,
        relativePath: String,
        representation: RemoteFileRepresentation,
        container: String? = nil,
        mimeType: String? = nil
    ) {
        self.accountID = accountID
        self.sourceID = sourceID
        self.credentialRevision = credentialRevision
        self.relativePath = relativePath
        self.representation = representation
        self.container = container
        self.mimeType = mimeType
    }

    /// Rebuilds the validated ``NetworkFileLocator`` the transport resolver reads.
    public func makeLocator() throws -> NetworkFileLocator {
        try NetworkFileLocator(
            accountID: accountID,
            sourceID: sourceID,
            credentialRevision: credentialRevision,
            relativePath: relativePath,
            representation: representation,
            formatHint: MediaFormatHint(container: container, mimeType: mimeType)
        )
    }
}

public extension DirectShareDownloadSource {
    /// Convenience: derive a source from a fully-formed locator (plus optional
    /// format hints, which the locator does not expose back out).
    init(
        locator: NetworkFileLocator,
        container: String? = nil,
        mimeType: String? = nil
    ) {
        self.init(
            accountID: locator.accountID,
            sourceID: locator.sourceID,
            credentialRevision: locator.credentialRevision,
            relativePath: locator.relativePath,
            representation: locator.representation,
            container: container,
            mimeType: mimeType
        )
    }
}
