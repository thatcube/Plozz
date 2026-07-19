import CoreModels
import Foundation

/// A stable, deterministic string form of a ``MediaIdentity`` used to key
/// download records and to name a download's on-disk folder.
///
/// It must be **stable across launches and app versions** (it addresses a pinned
/// file), so it is derived structurally from the identity's cases — never from a
/// Swift type name or a non-deterministic hash.
public enum MediaIdentityKey {
    /// The canonical key string for an identity.
    public static func string(for identity: MediaIdentity) -> String {
        switch identity {
        case let .external(source, value):
            return "ext\u{1}\(source)\u{1}\(value)"
        case let .title(normalizedTitle, year, kind):
            return "title\u{1}\(normalizedTitle)\u{1}\(year.map(String.init) ?? "")\u{1}\(kind.rawValue)"
        case let .sameItemID(id):
            return "same\u{1}\(id)"
        }
    }

    /// A filesystem-safe, collision-free folder name for an identity key
    /// (base64url of the key's UTF-8, matching ``DurableLocalStateKey``'s
    /// component encoding).
    public static func folderName(for identity: MediaIdentity) -> String {
        folderName(forKey: string(for: identity))
    }

    /// A filesystem-safe folder name for an already-computed key.
    public static func folderName(forKey key: String) -> String {
        Data(key.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
