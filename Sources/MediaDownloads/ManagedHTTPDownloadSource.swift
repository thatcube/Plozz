import CoreModels
import Foundation

/// Secret-free reopen information for a managed-provider background download.
///
/// Credentials and resolved URLs are deliberately excluded. The iOS app resolves
/// a fresh authenticated URL from the active account each time work starts or
/// resumes.
public struct ManagedHTTPDownloadSource: Codable, Sendable, Hashable {
    public let provider: ProviderKind
    public let accountID: String
    public let itemID: String
    public let mediaSourceID: String?

    public init(
        provider: ProviderKind,
        accountID: String,
        itemID: String,
        mediaSourceID: String? = nil
    ) {
        self.provider = provider
        self.accountID = accountID
        self.itemID = itemID
        self.mediaSourceID = mediaSourceID
    }
}
