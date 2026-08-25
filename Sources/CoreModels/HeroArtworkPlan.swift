import Foundation

/// Where a piece of wide artwork came from. Used to keep the two hero screens off
/// the same *source*, not merely off the same URL — see ``HeroArtworkPlanner``.
public enum HeroArtworkOrigin: String, Codable, Hashable, Sendable {
    /// The media server's own art: a Jellyfin/Emby backdrop, a Plex `art` or
    /// `background`, a file sitting in the share next to the media.
    case server
    /// An online metadata provider: TMDb, TheTVDB, AniList, Kitsu.
    case external
}

/// How much is known about whether a picture has the show's title burned into it.
///
/// A hero draws the show's *logo* over its backdrop, so a backdrop that already
/// carries the title renders the name twice — the single worst thing wide artwork
/// can do here. Ranked, not merely flagged, because "we know this one is clean"
/// deserves to beat "this might be fine".
public enum HeroArtworkTextPresence: Int, Codable, Hashable, Sendable, Comparable {
    /// Known clean — a TMDb backdrop with no language attached, or a file the
    /// share tagged as textless.
    case textless = 0
    /// A server backdrop. It may or may not carry the title; nothing has looked.
    case unknown = 1
    /// Known to carry the title. Usable, but only when nothing else is.
    case titled = 2

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One piece of wide artwork a title could show, with everything the planner needs
/// to rank it.
public struct HeroArtworkCandidate: Hashable, Sendable {
    public let reference: ArtworkReference
    public let origin: HeroArtworkOrigin
    public let text: HeroArtworkTextPresence
    /// Preference *within* a tier, higher first. A provider's own ordering, a TMDb
    /// vote average — whatever the caller already knows. Ties keep the order the
    /// caller supplied.
    public let score: Double

    public init(
        reference: ArtworkReference,
        origin: HeroArtworkOrigin,
        text: HeroArtworkTextPresence = .unknown,
        score: Double = 0
    ) {
        self.reference = reference
        self.origin = origin
        self.text = text
        self.score = score
    }
}

/// Decides which picture the Home hero shows and which one the detail page shows,
/// from one pool of a title's wide artwork.
///
/// Every backend — Jellyfin, Emby, Plex, a local share — collects whatever wide art
/// it already has in the response it already made, hands the pool here, and gets
/// back per-placement selections. One policy, so a show looks the same way round on
/// every server rather than each provider inventing its own rule.
///
/// **The hierarchy**, in order:
///
/// 1. **Textless wins.** The hero draws the logo on top, so a backdrop carrying the
///    title writes the name twice.
/// 2. **Then the caller's own preference** (``HeroArtworkCandidate/score``), which
///    is where a server's ordering or a TMDb vote average lands.
/// 3. **Then the order supplied**, so the ranking is total and a rebuild can't
///    reshuffle two equal candidates and swap a title's artwork for nothing.
///
/// **The guarantee.** The detail page is given the first candidate whose *reference*
/// differs from Home's, preferring one whose ``HeroArtworkCandidate/origin`` differs
/// too — so where a title has both server art and an online backdrop, the two
/// screens are drawn from different sources rather than two crops of one shoot. The
/// two placements are only ever equal when the pool holds a single distinct image,
/// which is a fact about the library and not a decision made here.
public enum HeroArtworkPlanner {

    /// Per-placement selections for a title, best-first, or an empty array when
    /// there is nothing to say.
    ///
    /// Each placement gets the whole pool as an ordered ladder rather than one URL:
    /// its own pick first, then everything else. A hero whose chosen image 404s
    /// (artwork a server lists but no longer holds) then falls to the next real
    /// picture instead of to the text fallback.
    public static func selections(for candidates: [HeroArtworkCandidate]) -> [ArtworkSelection] {
        let ranked = rank(candidates)
        guard let home = ranked.first else { return [] }
        let detail = detailPick(from: ranked, home: home) ?? home

        return [
            ArtworkSelection(placement: .homeHero, references: ladder(from: ranked, leading: home)),
            ArtworkSelection(placement: .detailBackdrop, references: ladder(from: ranked, leading: detail))
        ]
    }

    /// The pool ordered by the hierarchy above, de-duplicated by reference so the
    /// same URL arriving from two sources cannot occupy both hero slots.
    static func rank(_ candidates: [HeroArtworkCandidate]) -> [HeroArtworkCandidate] {
        var seen = Set<ArtworkReference>()
        let unique = candidates.filter { seen.insert($0.reference).inserted }
        // Sorting on the index as the final key makes this stable. Swift's sort is
        // not, and an unstable order here would let a rebuild swap two equally
        // ranked backdrops and change a title's artwork for no reason.
        return unique.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.text != rhs.element.text { return lhs.element.text < rhs.element.text }
                if lhs.element.score != rhs.element.score { return lhs.element.score > rhs.element.score }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// The best candidate that is not the one Home is showing, preferring a
    /// different origin so the two screens aren't two frames of the same shoot.
    private static func detailPick(
        from ranked: [HeroArtworkCandidate],
        home: HeroArtworkCandidate
    ) -> HeroArtworkCandidate? {
        let others = ranked.filter { $0.reference != home.reference }
        return others.first { $0.origin != home.origin } ?? others.first
    }

    /// `leading` first, then the rest of the pool in rank order, as a fallback
    /// ladder.
    private static func ladder(
        from ranked: [HeroArtworkCandidate],
        leading: HeroArtworkCandidate
    ) -> [ArtworkReference] {
        [leading.reference] + ranked.map(\.reference).filter { $0 != leading.reference }
    }
}
