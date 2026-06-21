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

    /// Builds the deep link that launches Plozz straight into an item.
    /// Example: `plozz://item/abc123`.
    public static func itemDeepLink(id: String) -> URL {
        var components = URLComponents()
        components.scheme = deepLinkScheme
        components.host = itemHost
        components.path = "/" + id
        return components.url ?? URL(string: "\(deepLinkScheme)://\(itemHost)/\(id)")!
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
