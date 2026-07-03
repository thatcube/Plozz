import Foundation
import CoreModels

/// Second-class local media-share provider (SMB). Conforms to `MediaProvider`
/// so Home / browse / search / playback treat a share like any other backend —
/// but everything a real server would compute (libraries, detail, search) is
/// synthesised from a local scan (`ShareLibraryStore`) instead of network calls.
///
/// The share connection is carried by the ordinary `UserSession`: the synthetic
/// `MediaServer.baseURL` is `smb://host[:port]/share`, `session.userName` is the
/// SMB account (or "guest"), and `session.accessToken` is the password (already
/// Keychain-backed by `SessionStore`). Playback hands back an `smb://` URL that
/// `EnginePlozzigen` turns into an engine `SMBConnection` custom source.
public struct ShareProvider: MediaProvider {
    public let kind: ProviderKind = .mediaShare
    public let session: UserSession

    private let store: ShareLibraryStore
    private let host: String
    private let port: Int?
    private let share: String

    public init(session: UserSession) {
        self.session = session
        let parsed = Self.parse(session.server.baseURL)
        self.host = parsed.host
        self.port = parsed.port
        self.share = parsed.share
        let browser = SMBShareBrowser(
            host: parsed.host, port: parsed.port, share: parsed.share,
            user: session.userName, password: session.accessToken
        )
        self.store = ShareLibraryStore(browser: browser, serverName: session.server.name)
    }

    // MARK: Library browsing

    public func libraries() async throws -> [MediaLibrary] {
        // Home aggregation calls this at launch, so it must be instant — no
        // network. A share exposes exactly one browsable "library": its root
        // folder. The actual directory listing happens lazily the first time the
        // user opens the row (see `items(in:)` / `children(of:)`).
        await store.libraries()
    }

    public func continueWatching(limit: Int) async throws -> [MediaItem] {
        // No watch state yet (Phase 3). Nothing to resume.
        []
    }

    public func latest(limit: Int) async throws -> [MediaItem] {
        // Home-path method — must NOT touch the network (would block Home). A
        // "recently added" row from shares comes in a later phase.
        []
    }

    public func item(id: String) async throws -> MediaItem {
        guard let item = await store.item(id: id) else {
            throw AppError.unknown("Item not found on share: \(id)")
        }
        return item
    }

    public func children(of itemID: String) async throws -> [MediaItem] {
        // A folder's children are just that directory's listing.
        try await store.entries(forContainerID: itemID)
    }

    public func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        // Browsing the root library (or any folder) lists exactly that directory.
        let all = try await store.entries(forContainerID: containerID)
        let start = min(page.startIndex, all.count)
        let end = min(start + page.limit, all.count)
        return MediaPage(items: Array(all[start..<end]), startIndex: start, totalCount: all.count)
    }

    // MARK: Search

    public func search(query: String, limit: Int) async throws -> [MediaItem] {
        try await store.search(query: query, limit: limit)
    }

    // MARK: Playback

    public func playbackInfo(for itemID: String) async throws -> PlaybackRequest {
        let item = try await item(id: itemID)
        guard let relPath = await store.path(forItemID: itemID) else {
            throw AppError.unknown("Item is not directly playable: \(itemID)")
        }
        guard let url = smbURL(forRelativePath: relPath) else {
            throw AppError.unknown("Couldn't build a stream URL for \(relPath)")
        }
        return PlaybackRequest(
            item: item,
            streamURL: url,
            startPosition: 0,
            sourceProvider: .mediaShare,
            serverName: session.server.name
        )
    }

    public func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {
        // No server to report to; local watch state arrives in Phase 3.
    }

    // MARK: Images

    public func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? {
        // Artwork via MetadataKit (TMDb) lands in Phase 2c. No poster for now.
        nil
    }

    // MARK: - SMB URL

    /// Build `smb://[user[:password]@]host[:port]/share/<relPath>` with each
    /// path segment percent-encoded, for the engine's custom SMB source.
    private func smbURL(forRelativePath relPath: String) -> URL? {
        var comps = URLComponents()
        comps.scheme = "smb"
        comps.host = Self.bracketedHostIfIPv6(host)
        comps.port = port
        if !session.userName.isEmpty {
            comps.user = session.userName
            if !session.accessToken.isEmpty { comps.password = session.accessToken }
        }
        // Share + each relative segment, joined so URLComponents percent-encodes
        // spaces and other reserved characters correctly.
        let segments = [share] + relPath.split(separator: "/").map(String.init)
        comps.path = "/" + segments.joined(separator: "/")
        return comps.url
    }

    /// URLComponents produces `nil` for a bare IPv6 literal host (e.g. `fe80::1`)
    /// — it must be bracketed. IPv4 and hostnames never contain a colon, so this
    /// only wraps genuine IPv6 literals (and leaves already-bracketed ones alone).
    public static func bracketedHostIfIPv6(_ host: String) -> String {
        guard host.contains(":"), !host.hasPrefix("[") else { return host }
        return "[\(host)]"
    }

    // MARK: - Parse baseURL

    private static func parse(_ baseURL: URL) -> (host: String, port: Int?, share: String) {
        let comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let host = comps?.host ?? ""
        let port = comps?.port
        let share = (comps?.path ?? "")
            .split(separator: "/", omittingEmptySubsequences: true)
            .first.map(String.init) ?? ""
        return (host, port, share)
    }
}
