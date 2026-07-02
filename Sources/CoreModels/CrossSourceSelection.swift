import Foundation

/// A concrete "play this, from here" choice across every server that holds a
/// merged title: which server (``source``) and, within it, which file
/// (``version``, `nil` = that server's default).
public struct CrossSourceSelection: Sendable, Hashable {
    public var source: MediaSourceRef
    public var version: MediaVersion?

    public init(source: MediaSourceRef, version: MediaVersion?) {
        self.source = source
        self.version = version
    }
}

/// Picks the best server+version to play **by default** for a merged title.
///
/// It extends the single-server smart default
/// (``Swift/Array/recommendedSelection(for:)``) across servers: each source's own
/// best version is evaluated for this device, then ranked so the user gets the
/// highest-quality option their Apple TV can **Direct Play** without a transcode,
/// while every other server stays available as an explicit pick / fallback.
///
/// Ranking (highest first):
/// 0. **Local beats remote** — a copy on the same LAN as the Apple TV always
///    wins over one reached over the internet / a Tailscale tunnel, *before*
///    quality is even considered: a local 1080p that streams instantly is a
///    better default than a remote 4K that buffers over a relay. Sources of
///    unknown locality sit between known-local and known-remote so an
///    unclassifiable host never loses to a known-remote server.
/// 1. **Direct Play beats Transcode** — a 1080p file that plays untouched is a
///    better default than a 4K file the server must transcode (mirrors the
///    single-server policy).
/// 2. **Known beats unknown** — a source whose versions are loaded beats one
///    whose file list hasn't been fetched yet.
/// 3. **Higher quality** — `qualityScore` (resolution → HDR → bitrate).
/// 4. **Primary first** — stable tie-break so a file mirrored identically on two
///    servers deterministically resolves to the primary source.
public enum CrossSourceSelector {
    private struct Candidate {
        var order: Int
        var source: MediaSourceRef
        var version: MediaVersion?
        var localityRank: Int
        var directPlays: Bool
        var hasVersions: Bool
        var qualityScore: Int
    }

    /// The default server+version to play for `item`, or `nil` when `item` has no
    /// `sources` (a single-server item — callers fall back to
    /// `item.versions.recommendedSelection(for:)`).
    public static func bestSelection(
        for item: MediaItem,
        capabilities: MediaCapabilities
    ) -> CrossSourceSelection? {
        bestSelection(from: item.sources, capabilities: capabilities)
    }

    /// The default server+version to play across `sources`, or `nil` when empty.
    public static func bestSelection(
        from sources: [MediaSourceRef],
        capabilities: MediaCapabilities
    ) -> CrossSourceSelection? {
        guard !sources.isEmpty else { return nil }

        let candidates = sources.enumerated().map { offset, source -> Candidate in
            let localityRank = (source.locality ?? .unknown).rank
            if let best = source.versions.recommendedSelection(for: capabilities) {
                return Candidate(
                    order: offset,
                    source: source,
                    version: best,
                    localityRank: localityRank,
                    directPlays: best.compatibility(with: capabilities) == .directPlay,
                    hasVersions: true,
                    qualityScore: best.qualityScore
                )
            }
            return Candidate(
                order: offset,
                source: source,
                version: nil,
                localityRank: localityRank,
                directPlays: false,
                hasVersions: false,
                qualityScore: Int.min
            )
        }

        let winner = candidates.max { lhs, rhs in
            if lhs.localityRank != rhs.localityRank { return lhs.localityRank < rhs.localityRank }
            if lhs.directPlays != rhs.directPlays { return !lhs.directPlays && rhs.directPlays }
            if lhs.hasVersions != rhs.hasVersions { return !lhs.hasVersions && rhs.hasVersions }
            if lhs.qualityScore != rhs.qualityScore { return lhs.qualityScore < rhs.qualityScore }
            // Lower order (primary) should win the tie → it must be the "max".
            return lhs.order > rhs.order
        }

        guard let winner else { return nil }
        return CrossSourceSelection(source: winner.source, version: winner.version)
    }

    /// The default server+version to play across `sources`, honoring an explicit
    /// **origin** preference.
    ///
    /// When `preferredAccountID` matches one of the `sources` — i.e. the item was
    /// opened from *that* server's library tile — that source is the default, with
    /// its own smart recommended version selected, so the detail page and playback
    /// follow the library's server (the picker still lets the user switch). When
    /// `preferredAccountID` is `nil` or no source matches it (e.g. a title opened
    /// from a cross-server-merged Home/Search row), it falls back to the smart
    /// cross-server best (``bestSelection(from:capabilities:)``).
    public static func selection(
        from sources: [MediaSourceRef],
        capabilities: MediaCapabilities,
        preferredAccountID: String?
    ) -> CrossSourceSelection? {
        guard !sources.isEmpty else { return nil }
        if let preferredAccountID,
           let origin = sources.first(where: { $0.accountID == preferredAccountID }) {
            return CrossSourceSelection(
                source: origin,
                version: origin.versions.recommendedSelection(for: capabilities)
            )
        }
        return bestSelection(from: sources, capabilities: capabilities)
    }
}
