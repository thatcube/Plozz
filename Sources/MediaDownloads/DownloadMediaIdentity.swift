import CoreModels

/// Chooses the durable registry key used for an offline copy.
public enum DownloadMediaIdentity {
    static let accountSourcePrefix = "plozz-account:"

    public static func primary(for item: MediaItem) -> MediaIdentity? {
        if let identity = MediaItemIdentity.identities(for: item).first {
            return identity
        }
        guard let accountID = item.sourceAccountID, !accountID.isEmpty else {
            return nil
        }
        return .external(
            source: "\(accountSourcePrefix)\(accountID)",
            value: item.id
        )
    }
}
