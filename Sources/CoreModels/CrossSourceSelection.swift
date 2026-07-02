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
        var isPreferred: Bool
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
    ///
    /// `preferring` is a **soft** origin/library hint used only as the *last*
    /// tie-break (after locality, Direct-Play, known-versions and quality): when
    /// the item was opened from a particular server's library tile, that server
    /// wins **only** among otherwise-equal candidates. It never overrides
    /// locality — a local copy still beats a remote/Tailscale origin — so the
    /// "play from the closest server" guarantee holds while a genuine tie
    /// resolves to the browsed library deterministically.
    public static func bestSelection(
        from sources: [MediaSourceRef],
        capabilities: MediaCapabilities,
        preferring preferredAccountID: String? = nil,
        excluding excludedAccountIDs: Set<String> = []
    ) -> CrossSourceSelection? {
        // Drop sources on servers already attempted (failover). Done first so an
        // empty remainder returns `nil` (true exhaustion) rather than re-selecting
        // a server that just failed.
        let pool = excludedAccountIDs.isEmpty
            ? sources
            : sources.filter { !excludedAccountIDs.contains($0.accountID) }
        guard !pool.isEmpty else { return nil }

        let candidates = pool.enumerated().map { offset, source -> Candidate in
            let localityRank = (source.locality ?? .unknown).rank
            let isPreferred = preferredAccountID != nil && source.accountID == preferredAccountID
            if let best = source.versions.recommendedSelection(for: capabilities) {
                return Candidate(
                    order: offset,
                    source: source,
                    version: best,
                    localityRank: localityRank,
                    directPlays: best.compatibility(with: capabilities) == .directPlay,
                    hasVersions: true,
                    qualityScore: best.qualityScore,
                    isPreferred: isPreferred
                )
            }
            return Candidate(
                order: offset,
                source: source,
                version: nil,
                localityRank: localityRank,
                directPlays: false,
                hasVersions: false,
                qualityScore: Int.min,
                isPreferred: isPreferred
            )
        }

        let winner = candidates.max { lhs, rhs in
            if lhs.localityRank != rhs.localityRank { return lhs.localityRank < rhs.localityRank }
            if lhs.directPlays != rhs.directPlays { return !lhs.directPlays && rhs.directPlays }
            if lhs.hasVersions != rhs.hasVersions { return !lhs.hasVersions && rhs.hasVersions }
            if lhs.qualityScore != rhs.qualityScore { return lhs.qualityScore < rhs.qualityScore }
            // Soft origin/library preference: only breaks an otherwise-exact tie.
            if lhs.isPreferred != rhs.isPreferred { return !lhs.isPreferred && rhs.isPreferred }
            // Lower order (primary) should win the tie → it must be the "max".
            return lhs.order > rhs.order
        }

        guard let winner else { return nil }
        return CrossSourceSelection(source: winner.source, version: winner.version)
    }
}
