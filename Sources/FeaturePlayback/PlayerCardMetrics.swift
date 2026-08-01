#if canImport(SwiftUI)
import SwiftUI
import CoreUI

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
enum PlayerCardLayout {
    /// The tvOS/iPad card: a wide, short band of columns sitting under the
    /// transport, so as little of the video as possible is covered.
    case horizontal
    /// The phone card: a tall column. A narrow screen has height to spare and no
    /// width at all, and the video — letterboxed into a strip across the middle —
    /// leaves most of the screen black anyway, so covering it costs nothing.
    /// Apple's own player does exactly this between portrait and landscape.
    case vertical
}

struct PlayerCardMetrics: Equatable {
    var layout: PlayerCardLayout
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
    /// The card's own corner radius.
    ///
    /// Scaled down with the card, because a radius is only ever right relative to
    /// the box it rounds: 52 reads as a softly rounded edge on a 240pt band and
    /// as a lozenge on a 152pt one.
    var panelCornerRadius: CGFloat
    /// How much to shrink the capability badges — see `mediaBadgeScale`.
    var badgeScale: CGFloat
    /// In the vertical layout, the height of one cast row.
    var castRowHeight: CGFloat

    /// The card's **exact** laid-out height, known up front rather than measured.
    ///
    /// Everything in the card is pinned to `contentHeight`, so this is
    /// deterministic. `PlayerControls` needs it before the first frame to park
    /// the cluster with the card just off-screen — measuring it instead meant the
    /// parked offset changed the moment the measurement landed (and again
    /// whenever metadata arrived), which showed up as the transport jumping.
    var cardHeight: CGFloat { contentHeight + contentPadding * 2 }
    /// Whether the card is a tall column rather than a wide band.
    var isVertical: Bool { layout == .vertical }
    /// A cast face card's width: the headshot plus the space either side.
    var castCardWidth: CGFloat { castHeadshot + castHeadshotSideSpace * 2 }
    /// Where the circle sits inside a face card, so the drill can start the
    /// detail's headshot exactly on top of it.
    var castHeadshotOrigin: CGPoint {
        CGPoint(x: castHeadshotSideSpace, y: castVerticalInset)
    }

    /// Across a room, from a remote.
    static let tv = PlayerCardMetrics(
        layout: .horizontal,
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
        overviewLineLimit: 4,
        panelCornerRadius: PlozzTheme.Metrics.playerPanelCornerRadius,
        badgeScale: 1,
        castRowHeight: 0
    )

    /// A tablet at arm's length, with room for the full three-column card.
    static let regular = PlayerCardMetrics(
        layout: .horizontal,
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
        overviewLineLimit: 4,
        panelCornerRadius: PlozzTheme.Metrics.playerPanelCornerRadius,
        badgeScale: 1,
        castRowHeight: 0
    )

    /// A phone, or an iPad window narrowed to about one.
    ///
    /// `contentHeight` is a **ceiling** here rather than a fixed height: the card
    /// grows to its content and stops there, because a vertical card holds a list
    /// whose length is not known up front. It is overwritten by `resolved` with a
    /// share of the height actually available.
    static let compact = PlayerCardMetrics(
        layout: .vertical,
        contentHeight: 320,
        contentPadding: 14,
        showsThumbnail: false,
        titleFont: .system(size: 17, weight: .semibold),
        bodyFont: .system(size: 13),
        bodyLineHeight: 17,
        captionFont: .system(size: 11, weight: .medium),
        castHeadshot: 44,
        castHeadshotSideSpace: 12,
        castVerticalInset: 8,
        castIdentityWidth: 380,
        overviewLineLimit: 4,
        // A radius is only right relative to the box it rounds; 52 on a card this
        // narrow reads as a lozenge.
        panelCornerRadius: 22,
        badgeScale: 0.62,
        castRowHeight: 64
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

    /// The share of the screen a vertical card may take.
    ///
    /// It is a share rather than a number because the two orientations it has to
    /// serve are nothing alike: a portrait phone has ~800pt to spend and the
    /// video occupies a strip across the middle, while the same phone in
    /// landscape has ~390 and the video fills it. Bounded at both ends so the
    /// card is never too short to hold a list, nor tall enough to swallow a
    /// portrait screen.
    private static let verticalHeightShare: CGFloat = 0.46
    private static let verticalHeightRange: ClosedRange<CGFloat> = 190...460

    /// Pick the metrics for the space the card has actually been given.
    static func resolved(forWidth width: CGFloat, height: CGFloat) -> PlayerCardMetrics {
        #if os(tvOS)
        return .tv
        #else
        // Zero on the very first pass, before the geometry reader has reported.
        // Assume the roomy layout rather than the cramped one: a card that starts
        // full and stays full is the common case, and guessing compact would make
        // every iPad open with a visible re-layout.
        guard width > 0 else { return .regular }
        guard width < thumbnailLayoutMinimumWidth else { return .regular }

        var metrics = compact
        if height > 0 {
            let budget = (height * verticalHeightShare).rounded()
            metrics.contentHeight = min(
                max(budget, verticalHeightRange.lowerBound),
                verticalHeightRange.upperBound
            ) - metrics.contentPadding * 2
        }
        return metrics
        #endif
    }
}

/// Pins the card's height in the horizontal layout and caps it in the vertical
/// one.
///
/// The horizontal card promises an exact height, because tvOS parks the
/// transport by it before the first frame — measuring it instead meant the
/// parked offset moved the moment the measurement landed. A vertical card cannot
/// make that promise: it holds a list, and its length is not known up front. It
/// takes what it needs and stops at the ceiling.
struct PlayerCardHeight: ViewModifier {
    let metrics: PlayerCardMetrics

    func body(content: Content) -> some View {
        if metrics.isVertical {
            content.frame(maxHeight: metrics.cardHeight)
        } else {
            content.frame(height: metrics.cardHeight)
        }
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
