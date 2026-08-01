#if canImport(SwiftUI)
import SwiftUI

/// Every number the player's Info and Cast cards are built from, in one value
/// chosen at layout time from the width actually available.
///
/// It replaces a set of `static` constants that were selected by device idiom.
/// Idiom is the wrong signal, and a resizable iPad window is the proof: the
/// idiom stays `.pad` while the window narrows to phone width, so the card kept
/// its three-column, 370pt-thumbnail layout in a space that could not hold it.
/// What the card actually needs to know is how much room it has, which only the
/// layout can answer.
///
/// Bundling the numbers rather than passing a size class is what makes the
/// change tractable. The cast face cards, the drill pane and the credit posters
/// all derive from `contentHeight` and `contentPadding`, so they follow from two
/// values here — and the drill animation, which measures card frames and grows a
/// pane between them, keeps working untouched because both ends move together.
struct PlayerCardMetrics: Equatable {
    /// The height of the card's content — the thumbnail when there is one, and
    /// the columns beside it either way.
    var contentHeight: CGFloat
    /// Padding between the card's content and its glass edge.
    var contentPadding: CGFloat
    /// Whether there is room for the 16:9 still.
    ///
    /// The first thing to go when space is short, and not only because it is the
    /// largest single element (370pt wide at the regular height, over half a
    /// narrow window). It is also the most redundant thing on the card: the
    /// video it depicts is playing at full size directly behind it.
    var showsThumbnail: Bool
    /// Titles: the episode/film name, a person's name.
    var titleFont: Font
    /// Running prose: a synopsis, a biography.
    var bodyFont: Font
    /// Its line height, for height budgeting.
    var bodyLineHeight: CGFloat
    /// Supporting detail: the meta row, a character name.
    var captionFont: Font
    /// Diameter of a cast member's headshot.
    var castHeadshot: CGFloat
    /// The space either side of it, so enlarging the face widens the card rather
    /// than crowding it.
    var castHeadshotSideSpace: CGFloat
    /// The headshot's inset from the top of its card.
    var castVerticalInset: CGFloat
    /// Width of the name-and-biography column in a cast member's detail pane.
    var castIdentityWidth: CGFloat
    /// How many lines of synopsis the Info card shows.
    var overviewLineLimit: Int

    /// The card's **exact** laid-out height, known up front rather than measured.
    ///
    /// Everything in the card is pinned to `contentHeight`, so this is
    /// deterministic. `PlayerControls` needs it before the first frame to park
    /// the cluster with the card just off-screen — measuring it instead meant the
    /// parked offset changed the moment the measurement landed (and again
    /// whenever metadata arrived), which showed up as the transport jumping.
    var cardHeight: CGFloat { contentHeight + contentPadding * 2 }
    /// A cast face card's width: the headshot plus the space either side.
    var castCardWidth: CGFloat { castHeadshot + castHeadshotSideSpace * 2 }
    /// Where the circle sits inside a face card, so the drill can start the
    /// detail's headshot exactly on top of it.
    var castHeadshotOrigin: CGPoint {
        CGPoint(x: castHeadshotSideSpace, y: castVerticalInset)
    }

    /// Across a room, from a remote.
    static let tv = PlayerCardMetrics(
        contentHeight: 250,
        contentPadding: 24,
        showsThumbnail: true,
        titleFont: .system(size: 34, weight: .bold),
        bodyFont: .system(size: 25),
        bodyLineHeight: 30,
        captionFont: .system(size: 22, weight: .medium),
        castHeadshot: 160,
        castHeadshotSideSpace: 31,
        castVerticalInset: 18,
        castIdentityWidth: 900,
        overviewLineLimit: 4
    )

    /// A tablet at arm's length, with room for the full three-column card.
    static let regular = PlayerCardMetrics(
        contentHeight: 208,
        contentPadding: 16,
        showsThumbnail: true,
        titleFont: .system(size: 34, weight: .bold),
        bodyFont: .system(size: 25),
        bodyLineHeight: 30,
        captionFont: .system(size: 22, weight: .medium),
        castHeadshot: 128,
        castHeadshotSideSpace: 24,
        castVerticalInset: 12,
        castIdentityWidth: 900,
        overviewLineLimit: 4
    )

    /// A phone, or an iPad window narrowed to about one.
    ///
    /// 128 + 12 padding lands the card at 152 — roughly a third of an iPhone's
    /// landscape height, which is as much as a card *describing* the video can
    /// take before it buries it.
    static let compact = PlayerCardMetrics(
        contentHeight: 128,
        contentPadding: 12,
        showsThumbnail: false,
        titleFont: .system(size: 17, weight: .semibold),
        bodyFont: .system(size: 13),
        bodyLineHeight: 17,
        captionFont: .system(size: 11, weight: .medium),
        castHeadshot: 72,
        castHeadshotSideSpace: 12,
        castVerticalInset: 8,
        castIdentityWidth: 380,
        overviewLineLimit: 2
    )

    #if os(tvOS)
    static let platformDefault = tv
    #else
    static let platformDefault = regular
    #endif

    /// The widest the three-column card can be squeezed before it stops working.
    ///
    /// Its parts do not compress: the thumbnail is a fixed 16:9 at the content
    /// height (370pt), the action column is three icon buttons (~190), the gaps
    /// between the columns are 60, and the text column needs ~280 before a
    /// synopsis stops reading as prose. That is the sum, and below it the card
    /// does not get tighter — it gets clipped, which is what a narrowed window
    /// was showing.
    static let thumbnailLayoutMinimumWidth: CGFloat = 900

    /// Pick the metrics for the width the card has actually been given.
    static func resolved(forWidth width: CGFloat) -> PlayerCardMetrics {
        #if os(tvOS)
        return .tv
        #else
        // Zero on the very first pass, before the geometry reader has reported.
        // Assume the roomy layout rather than the cramped one: a card that
        // starts full and stays full is the common case, and guessing compact
        // would make every iPad open with a visible re-layout.
        guard width > 0 else { return .regular }
        return width >= thumbnailLayoutMinimumWidth ? .regular : .compact
        #endif
    }
}

private struct PlayerCardMetricsKey: EnvironmentKey {
    static let defaultValue = PlayerCardMetrics.platformDefault
}

extension EnvironmentValues {
    /// The metrics the player's cards should lay themselves out with.
    ///
    /// Read rather than passed, because the parts that need it are private views
    /// nested three deep (a face card, a detail pane, a credits row) and
    /// threading a parameter through each of them would put the number in a
    /// dozen initialisers that have no other reason to know about it.
    var playerCardMetrics: PlayerCardMetrics {
        get { self[PlayerCardMetricsKey.self] }
        set { self[PlayerCardMetricsKey.self] = newValue }
    }
}
#endif
