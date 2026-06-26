import Foundation

// MARK: - Unified, de-duplicated music library seam
//
// Plozz can sign into Plex **and** Jellyfin and surface up to many music
// libraries at once. The browse experience must read as **one** combined
// library, not N servers stitched together, so the same album/artist that
// exists on two servers appears once.
//
// This file is the single place that decides "these are the same release" and
// the single place that merges per-source lists into a combined, de-duplicated
// list. Keeping both here means:
//   * every call site (landing rails, paged grids, recently played) de-dups
//     identically — there is no second concatenation path to forget, and
//   * the *definition* of a duplicate can grow stronger later (e.g. matching on
//     a provider GUID / MusicBrainz id) by editing one helper, not every screen.
//
// The merge preserves provenance: each merged item keeps a `MusicSourceRef` for
// every contributing library, so a future "play the best of N servers" feature
// is a value read off `item.sources`, not a re-architecture.

/// Computes the normalized identity key used to detect the same music release
/// across different servers.
public enum MusicIdentity {
    /// Folds a free-text field into a comparison key: diacritic- and
    /// case-insensitive, punctuation **removed** (so `"Pepper's"` == `"Peppers"`
    /// and `"AC/DC"` == `"ACDC"`), and real whitespace collapsed to single spaces
    /// (so word boundaries are preserved). `"Beyoncé"`, `"BEYONCE"` and
    /// `"beyonce"` all collide.
    public static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        var out = ""
        out.reserveCapacity(folded.count)
        var pendingSpace = false
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if pendingSpace, !out.isEmpty { out.append(" ") }
                pendingSpace = false
                out.unicodeScalars.append(scalar)
            } else if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                pendingSpace = true
            }
            // Any other punctuation/symbol is dropped entirely (no space), so an
            // in-word apostrophe or slash joins rather than splitting the word.
        }
        return out
    }

    /// Two albums are the same release when their title **and** primary artist
    /// normalize equally. Including the artist avoids collapsing distinct albums
    /// that merely share a common title (e.g. self-titled debuts).
    public static func key(for album: MusicAlbum) -> String {
        "album|\(normalize(album.title))|\(normalize(album.artistName ?? ""))"
    }

    public static func key(for artist: MusicArtist) -> String {
        "artist|\(normalize(artist.name))"
    }

    public static func key(for playlist: MusicPlaylist) -> String {
        "playlist|\(normalize(playlist.title))"
    }

    public static func key(for genre: MusicGenre) -> String {
        "genre|\(normalize(genre.name))"
    }

    /// A track is "the same song" when its title, primary artist **and** album
    /// normalize equally — enough to collapse the same song surfaced by two
    /// servers without merging distinct songs that merely share a title.
    public static func key(for track: MusicTrack) -> String {
        "track|\(normalize(track.title))|\(normalize(track.artistName ?? ""))|\(normalize(track.albumTitle ?? ""))"
    }
}

/// Merges music items gathered from several libraries into one combined,
/// de-duplicated list, preserving input order and recording every contributing
/// source on the surviving item.
public enum MusicMerge {
    /// De-duplicates `input` by `key`, keeping the **first** occurrence as the
    /// primary (so callers control precedence via input order) and attaching one
    /// `MusicSourceRef` per contributing copy — including the primary's own — to
    /// the survivor via `attach`.
    private static func deduplicate<T>(
        _ input: [T],
        key: (T) -> String,
        ref: (T) -> MusicSourceRef,
        attach: (T, [MusicSourceRef]) -> T
    ) -> [T] {
        var order: [String] = []
        var primary: [String: T] = [:]
        var refs: [String: [MusicSourceRef]] = [:]
        for item in input {
            let k = key(item)
            if primary[k] == nil {
                primary[k] = item
                order.append(k)
            }
            refs[k, default: []].append(ref(item))
        }
        return order.map { k in attach(primary[k]!, refs[k] ?? []) }
    }

    public static func albums(_ input: [MusicAlbum]) -> [MusicAlbum] {
        deduplicate(input, key: MusicIdentity.key(for:), ref: Self.ref(for:)) { item, sources in
            var copy = item
            copy.sources = sources
            return copy
        }
    }

    public static func artists(_ input: [MusicArtist]) -> [MusicArtist] {
        deduplicate(input, key: MusicIdentity.key(for:), ref: Self.ref(for:)) { item, sources in
            var copy = item
            copy.sources = sources
            return copy
        }
    }

    public static func playlists(_ input: [MusicPlaylist]) -> [MusicPlaylist] {
        deduplicate(input, key: MusicIdentity.key(for:), ref: Self.ref(for:)) { item, sources in
            var copy = item
            copy.sources = sources
            return copy
        }
    }

    public static func genres(_ input: [MusicGenre]) -> [MusicGenre] {
        deduplicate(input, key: MusicIdentity.key(for:), ref: Self.ref(for:)) { item, sources in
            var copy = item
            copy.sources = sources
            return copy
        }
    }

    /// Builds the unified "Recently Played" rail from albums gathered across
    /// every library: order by **real** last-played time (most recent first) so
    /// no single server's local ordering wins, then de-dup, then trim to `limit`.
    /// Albums without a timestamp sort last but are still included.
    public static func recentlyPlayedAlbums(_ input: [MusicAlbum], limit: Int) -> [MusicAlbum] {
        let sorted = input.sorted { lhs, rhs in
            switch (lhs.lastPlayedAt, rhs.lastPlayedAt) {
            case let (l?, r?): return l > r
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return false
            }
        }
        return Array(albums(sorted).prefix(max(0, limit)))
    }

    /// De-duplicates recently-played tracks across servers, keeping the first
    /// (most-recent, since callers pre-sort) occurrence of each song. `MusicTrack`
    /// has no `sources` accounting, so this is a plain first-wins de-dup.
    public static func tracks(_ input: [MusicTrack]) -> [MusicTrack] {
        var seen = Set<String>()
        var out: [MusicTrack] = []
        for track in input where seen.insert(MusicIdentity.key(for: track)).inserted {
            out.append(track)
        }
        return out
    }

    /// Builds the recently-played **tracks** rail: order by real last-played
    /// time (most recent first), de-dup the same song across servers, then trim.
    public static func recentlyPlayedTracks(_ input: [MusicTrack], limit: Int) -> [MusicTrack] {
        let sorted = input.sorted { lhs, rhs in
            switch (lhs.lastPlayedAt, rhs.lastPlayedAt) {
            case let (l?, r?): return l > r
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return false
            }
        }
        return Array(tracks(sorted).prefix(max(0, limit)))
    }

    /// Builds the unified "Recently Played" rail by interleaving recently-played
    /// **songs and albums** ordered by real play recency (most recent first).
    /// Each side is de-duplicated first, then the two are merged and trimmed so
    /// the rail stays at most `limit` cards regardless of the songs/albums split.
    public static func recentlyPlayedItems(albums: [MusicAlbum], tracks: [MusicTrack], limit: Int) -> [RecentlyPlayedItem] {
        let trimmedAlbums = recentlyPlayedAlbums(albums, limit: max(0, limit))
        let trimmedTracks = recentlyPlayedTracks(tracks, limit: max(0, limit))
        let items = trimmedAlbums.map(RecentlyPlayedItem.album) + trimmedTracks.map(RecentlyPlayedItem.track)
        let sorted = items.sorted { lhs, rhs in
            switch (lhs.lastPlayedAt, rhs.lastPlayedAt) {
            case let (l?, r?): return l > r
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return false
            }
        }
        return Array(sorted.prefix(max(0, limit)))
    }

    private static func ref(for album: MusicAlbum) -> MusicSourceRef {
        MusicSourceRef(accountID: album.sourceAccountID ?? "", itemID: album.id)
    }

    private static func ref(for artist: MusicArtist) -> MusicSourceRef {
        MusicSourceRef(accountID: artist.sourceAccountID ?? "", itemID: artist.id)
    }

    private static func ref(for playlist: MusicPlaylist) -> MusicSourceRef {
        MusicSourceRef(accountID: playlist.sourceAccountID ?? "", itemID: playlist.id)
    }

    private static func ref(for genre: MusicGenre) -> MusicSourceRef {
        MusicSourceRef(accountID: genre.sourceAccountID ?? "", itemID: genre.id)
    }
}
