import CoreModels

/// Device-wide local-artwork cache policy owned by the share runtime. ProviderShare
/// defines the boundary so accepted priority revisions can flow downward without a
/// dependency on AppShell or CoreUI.
public protocol ShareLocalArtworkCacheLifecycle: Sendable {
    func setPreferredAccountKeys(_ accountKeys: Set<String>, revision: UInt64) async
    func purge(accountID: String) async
    func purge(accountID: String, credentialRevision: CredentialRevision) async
}

public struct NoopShareLocalArtworkCacheLifecycle: ShareLocalArtworkCacheLifecycle {
    public init() {}

    public func setPreferredAccountKeys(_ accountKeys: Set<String>, revision: UInt64) async {}
    public func purge(accountID: String) async {}
    public func purge(accountID: String, credentialRevision: CredentialRevision) async {}
}
