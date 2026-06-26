import Foundation
import Observation
import CoreModels

// MARK: - Landing

/// Loads the Music tab landing content — a sample of albums, artists and
/// playlists merged across every music-capable account — plus drives navigation
/// to the full paged grids.
@MainActor
@Observable
public final class MusicLandingViewModel {
    public struct Content: Equatable, Sendable {
        public var albums: [MusicAlbum]
        public var artists: [MusicArtist]
        public var playlists: [MusicPlaylist]

        public var isEmpty: Bool { albums.isEmpty && artists.isEmpty && playlists.isEmpty }
    }

    public private(set) var state: LoadState<Content> = .idle

    private let context: MusicContext
    private let sampleSize: Int

    public init(context: MusicContext, sampleSize: Int = 18) {
        self.context = context
        self.sampleSize = sampleSize
    }

    public var hasPlaylists: Bool {
        if case let .loaded(content) = state { return !content.playlists.isEmpty }
        return false
    }

    public func load() async {
        state = .loading
        let accounts = context.musicAccounts
        let sampleSize = self.sampleSize

        // Fetch every (account × kind) request concurrently. Previously these ran
        // strictly serially — 3 round-trips per account, accounts back-to-back —
        // so the landing screen waited on the sum of every request. Running them
        // in one task group collapses that to roughly a single round-trip.
        let fetched = await withTaskGroup(
            of: (account: Int, kind: MusicItemKind, page: MusicPage?).self
        ) { group -> [(account: Int, kind: MusicItemKind, page: MusicPage?)] in
            for (index, account) in accounts.enumerated() {
                for kind in [MusicItemKind.album, .artist, .playlist] {
                    group.addTask {
                        let page = PageRequest(startIndex: 0, limit: sampleSize)
                        let result = try? await account.provider.musicItems(in: "", kind: kind, page: page)
                        return (index, kind, result)
                    }
                }
            }
            var results: [(account: Int, kind: MusicItemKind, page: MusicPage?)] = []
            for await result in group { results.append(result) }
            return results
        }

        // Reassemble in stable account order so the merged rails stay deterministic
        // regardless of which network response landed first.
        var albums: [MusicAlbum] = []
        var artists: [MusicArtist] = []
        var playlists: [MusicPlaylist] = []
        for (index, account) in accounts.enumerated() {
            for entry in fetched where entry.account == index {
                guard let result = entry.page else { continue }
                switch entry.kind {
                case .album: albums += result.albums.map { $0.taggingSource(account.accountID) }
                case .artist: artists += result.artists.map { $0.taggingSource(account.accountID) }
                case .playlist: playlists += result.playlists.map { $0.taggingSource(account.accountID) }
                default: break
                }
            }
        }

        let content = Content(
            albums: Array(albums.prefix(sampleSize)),
            artists: Array(artists.prefix(sampleSize)),
            playlists: Array(playlists.prefix(sampleSize))
        )
        state = content.isEmpty ? .empty : .loaded(content)
    }
}

// MARK: - Paged grid

/// A paged, multi-account grid of one music kind (artists / albums / playlists /
/// genres). Pages each account independently and merges the results, sorted by
/// display name, so large libraries don't over-fetch.
@MainActor
@Observable
public final class MusicGridViewModel {
    public let kind: MusicItemKind

    public private(set) var artists: [MusicArtist] = []
    public private(set) var albums: [MusicAlbum] = []
    public private(set) var playlists: [MusicPlaylist] = []
    public private(set) var genres: [MusicGenre] = []
    public private(set) var state: LoadState<Void> = .idle
    public private(set) var isLoadingMore = false

    private struct Pager {
        let account: ResolvedMusicAccount
        var nextIndex = 0
        var total = Int.max
        var finished = false
    }

    private var pagers: [Pager]
    private let containerID: String
    private let pageLimit: Int

    public init(context: MusicContext, kind: MusicItemKind, containerID: String = "", pageLimit: Int = 60) {
        self.kind = kind
        self.containerID = containerID
        self.pageLimit = pageLimit
        self.pagers = context.musicAccounts.map { Pager(account: $0) }
    }

    public var hasMore: Bool { pagers.contains { !$0.finished } }

    public var isEmpty: Bool {
        artists.isEmpty && albums.isEmpty && playlists.isEmpty && genres.isEmpty
    }

    public func loadFirstPageIfNeeded() async {
        guard case .idle = state else { return }
        await loadMore(initial: true)
    }

    public func loadMore() async {
        await loadMore(initial: false)
    }

    private func loadMore(initial: Bool) async {
        guard hasMore else { return }
        if initial { state = .loading } else { isLoadingMore = true }
        defer { isLoadingMore = false }

        for i in pagers.indices where !pagers[i].finished {
            let pager = pagers[i]
            let page = PageRequest(startIndex: pager.nextIndex, limit: pageLimit)
            guard let result = try? await pager.account.provider.musicItems(in: containerID, kind: kind, page: page) else {
                pagers[i].finished = true
                continue
            }
            merge(result, accountID: pager.account.accountID)
            pagers[i].total = result.totalCount
            pagers[i].nextIndex += max(result.count, 1)
            if result.count == 0 || pagers[i].nextIndex >= result.totalCount {
                pagers[i].finished = true
            }
        }

        sortAll()
        state = isEmpty ? .empty : .loaded(())
    }

    private func merge(_ page: MusicPage, accountID: String) {
        artists += page.artists.map { $0.taggingSource(accountID) }
        albums += page.albums.map { $0.taggingSource(accountID) }
        playlists += page.playlists.map { $0.taggingSource(accountID) }
        genres += page.genres.map { $0.taggingSource(accountID) }
    }

    private func sortAll() {
        artists.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        albums.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        playlists.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        genres.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

// MARK: - Artist detail

@MainActor
@Observable
public final class ArtistDetailViewModel {
    public private(set) var artist: MusicArtist
    public private(set) var albums: [MusicAlbum] = []
    public private(set) var state: LoadState<Void> = .idle

    private let provider: (any MusicProvider)?
    private let accountID: String?

    public init(artist: MusicArtist, context: MusicContext) {
        self.artist = artist
        self.accountID = artist.sourceAccountID
        self.provider = context.provider(for: artist.sourceAccountID)
    }

    public func load() async {
        guard let provider else { state = .empty; return }
        state = .loading
        let artistID = artist.id
        let tag = accountID ?? ""
        // Fetch the artist's refreshed metadata and album list concurrently —
        // they're independent, so there's no reason to wait for one before the
        // other.
        async let detailTask = try? await provider.artist(id: artistID)
        async let albumsTask = try? await provider.musicItems(
            in: artistID, kind: .album, page: PageRequest(startIndex: 0, limit: 100)
        )
        let detail = await detailTask
        let result = await albumsTask
        if let detail, !detail.name.isEmpty {
            artist = detail.taggingSource(tag)
        }
        if let result {
            albums = result.albums.map { $0.taggingSource(tag) }
        }
        state = albums.isEmpty ? .empty : .loaded(())
    }
}

// MARK: - Album detail

@MainActor
@Observable
public final class AlbumDetailViewModel {
    public private(set) var album: MusicAlbum
    public private(set) var tracks: [MusicTrack] = []
    public private(set) var state: LoadState<Void> = .idle

    private let accountID: String?
    public let provider: (any MusicProvider)?

    public init(album: MusicAlbum, context: MusicContext) {
        self.album = album
        self.accountID = album.sourceAccountID
        self.provider = context.provider(for: album.sourceAccountID)
    }

    public func load() async {
        guard let provider else { state = .empty; return }
        state = .loading
        let albumID = album.id
        let tag = accountID ?? ""
        // The album's refreshed metadata and its track list are independent —
        // fetch them concurrently so the screen fills in as fast as the slower
        // of the two, not their sum.
        async let detailTask = try? await provider.album(id: albumID)
        async let tracksTask = try? await provider.tracks(in: albumID)
        let detail = await detailTask
        let loaded = await tracksTask
        if let detail, !detail.title.isEmpty {
            album = detail.taggingSource(tag)
        }
        if let loaded {
            tracks = loaded.map { $0.taggingSource(tag) }
        }
        state = tracks.isEmpty ? .empty : .loaded(())
    }
}

// MARK: - Playlist detail

@MainActor
@Observable
public final class PlaylistDetailViewModel {
    public private(set) var playlist: MusicPlaylist
    public private(set) var tracks: [MusicTrack] = []
    public private(set) var state: LoadState<Void> = .idle

    private let accountID: String?
    public let provider: (any MusicProvider)?

    public init(playlist: MusicPlaylist, context: MusicContext) {
        self.playlist = playlist
        self.accountID = playlist.sourceAccountID
        self.provider = context.provider(for: playlist.sourceAccountID)
    }

    public func load() async {
        guard let provider else { state = .empty; return }
        state = .loading
        if let loaded = try? await provider.tracks(in: playlist.id) {
            tracks = loaded.map { $0.taggingSource(accountID ?? "") }
        }
        state = tracks.isEmpty ? .empty : .loaded(())
    }
}

// MARK: - Formatting helpers

public enum MusicFormat {
    /// Formats a duration like `3:07` or `1:02:33`.
    public static func duration(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}
