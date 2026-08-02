import Foundation

/// Shared constants and deep-link helpers that bridge the main app and the Top
/// Shelf extension. Both targets compile this file.
public enum TopShelf {
    /// App Group shared between the app and the Top Shelf extension. Must match
    /// the `com.apple.security.application-groups` entitlement on both targets.
    public static let appGroupID = "group.com.thatcube.Plozz"

    /// File name of the snapshot inside the shared container.
    public static let snapshotFileName = "topshelf-snapshot.json"

    /// Custom URL scheme Plozz registers for deep links.
    public static let deepLinkScheme = "plozz"

    /// Deep-link host used for "play this item" links.
    public static let itemHost = "item"

    /// A title addressed by a deep link: the server's local id plus **which**
    /// server it came from.
    ///
    /// The account matters. A bare item id is unique only within one server — Plex
    /// ratingKeys are small per-server integers — so a link carrying only an id can
    /// open the wrong title, or nothing at all, on a device signed in to more than
    /// one server. The app is multi-account by design, so the account travels with
    /// the link.
    public struct ItemReference: Hashable, Sendable {
        public let id: String
        public let accountID: String?

        public init(id: String, accountID: String? = nil) {
            self.id = id
            self.accountID = accountID
        }
    }

    /// Builds the deep link that launches Plozz straight into an item.
    /// Example: `plozz://item/abc123?account=jf-1`.
    public static func itemDeepLink(id: String, accountID: String? = nil) -> URL {
        var components = URLComponents()
        components.scheme = deepLinkScheme
        components.host = itemHost
        components.path = "/" + id
        if let accountID, !accountID.isEmpty {
            components.queryItems = [URLQueryItem(name: accountQueryItem, value: accountID)]
        }
        return components.url ?? URL(string: "\(deepLinkScheme)://\(itemHost)/\(id)")!
    }

    /// Query-item name carrying the owning account in an item deep link.
    public static let accountQueryItem = "account"

    /// Extracts the title a deep link addresses, or `nil` if the URL is not a
    /// recognised item link. Links written by older builds carry no account and
    /// decode with `accountID == nil`.
    public static func itemReference(from url: URL) -> ItemReference? {
        guard let id = itemID(from: url) else { return nil }
        let accountID = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == accountQueryItem }?
            .value
        return ItemReference(
            id: id,
            accountID: accountID.flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    /// Extracts the item id from a deep link, or `nil` if the URL is not a
    /// recognised item link.
    public static func itemID(from url: URL) -> String? {
        guard url.scheme?.lowercased() == deepLinkScheme,
              url.host?.lowercased() == itemHost
        else { return nil }

        let id = url.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }
}

/// Reads and writes the Top Shelf snapshot in the shared App Group container.
public enum TopShelfStore {
    private static var containerURL: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: TopShelf.appGroupID
        )
    }

    /// Directory inside the shared container where the snapshot lives.
    ///
    /// tvOS keeps the App Group container *root* read-only — only
    /// subdirectories such as `Library/Caches` are writable. Writing the
    /// snapshot to the root fails with `NSFileWriteNoPermissionError` (513), so
    /// it is stored under `Library/Caches` instead. Both the app and the
    /// extension resolve the same path through this property.
    private static var snapshotDirectoryURL: URL? {
        containerURL?
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
    }

    private static var snapshotURL: URL? {
        snapshotDirectoryURL?.appendingPathComponent(TopShelf.snapshotFileName)
    }

    /// Directory holding composited Continue-Watching posters (poster art with
    /// the progress bar burned in — see `TopShelfPosterComposer`). Lives beside
    /// the snapshot under the writable `Library/Caches` subtree so both the app
    /// (which writes) and the extension (which loads the files referenced by the
    /// snapshot) resolve the same absolute paths.
    public static var artworkDirectoryURL: URL? {
        snapshotDirectoryURL?.appendingPathComponent("topshelf-art", isDirectory: true)
    }

    /// Deletes composited posters whose filenames are no longer referenced by the
    /// freshly published snapshot, so stale/superseded art (old progress buckets,
    /// items that dropped off Continue Watching) doesn't accumulate. A no-op when
    /// the directory doesn't exist yet.
    public static func pruneArtwork(keeping keepFilenames: Set<String>) {
        guard let directory = artworkDirectoryURL else { return }
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return }
        for file in files where !keepFilenames.contains(file.lastPathComponent) {
            try? fileManager.removeItem(at: file)
        }
    }

    /// Persists the snapshot into the shared App Group container.
    ///
    /// The container directory is created on demand first: the system hands back
    /// a valid container URL even before the directory itself exists on disk, so
    /// a plain atomic write can fail with a "no permission" / "no such file"
    /// error. Creating the directory (and falling back to a non-atomic write)
    /// makes the first publish succeed.
    public static func save(_ snapshot: TopShelfSnapshot) {
        guard let directory = snapshotDirectoryURL, let url = snapshotURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(snapshot)

            do {
                try data.write(to: url, options: .atomic)
            } catch {
                // Atomic writes stage a temp file + rename, which can be denied
                // in some sandboxed container states; retry with a direct write.
                try data.write(to: url)
            }
        } catch {
            // Best-effort: a failed publish simply leaves the previous shelf.
        }
    }

    /// Loads the most recent snapshot, or `nil` if none exists yet.
    public static func load() -> TopShelfSnapshot? {
        guard let url = snapshotURL,
              let data = try? Data(contentsOf: url)
        else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(TopShelfSnapshot.self, from: data)
    }
}
