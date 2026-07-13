import Foundation

/// A `MediaLibrary` paired with the account/provider it came from.
///
/// The Home/Search aggregator builds these so a merged Libraries row can show
/// which server each library lives on, route a tapped library back to its owning
/// provider, and key the user's Home-visibility choices stably per account.
public struct AggregatedLibrary: Codable, Hashable, Identifiable, Sendable {
    /// The owning `Account.id`.
    public var accountID: String
    /// Display name of the account's user (for grouping headers).
    public var accountName: String
    /// Display name of the server the library lives on.
    public var serverName: String
    /// The backend the library came from.
    public var providerKind: ProviderKind
    /// For a media-share library, its file-share transport (SMB/WebDAV/…), so any
    /// surface that renders the share's drive icon can show the transport badge.
    /// `nil` for a dedicated media server (which shows its branded logo instead).
    public var transportKind: MediaShareTransportKind?
    /// The underlying provider-agnostic library.
    public var library: MediaLibrary

    public init(
        accountID: String,
        accountName: String,
        serverName: String,
        providerKind: ProviderKind,
        transportKind: MediaShareTransportKind? = nil,
        library: MediaLibrary
    ) {
        self.accountID = accountID
        self.accountName = accountName
        self.serverName = serverName
        self.providerKind = providerKind
        self.transportKind = transportKind
        self.library = library
    }

    /// A stable key unique across every account + library, used both as the
    /// `Identifiable` id and as the persistence key for Home-visibility choices.
    /// Stable across relaunches because it is derived only from persisted ids.
    public var key: String { "\(accountID):\(library.id)" }

    public var id: String { key }
}
