#if canImport(SwiftUI)
import SwiftUI
import CoreUI

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

/// Every number the player's Info and Cast cards are built from, interpolated at
/// layout time from the space actually available.
///
/// It replaces a set of `static` constants selected by device idiom. Idiom is the
/// wrong signal and a resizable iPad window is the proof: the idiom stays `.pad`
/// while the window narrows to phone width, so the card kept a layout that could
/// not fit. Only the layout knows how much room there is.
///
/// **Continuous, not stepped.** The presets below are anchors that get blended,
/// not modes that get chosen: iPads come in half a dozen sizes and a window can
/// be dragged to any width between them, so a card that is correct at two widths
/// and wrong in between is not responsive — it just has more breakpoints. Every
/// value here is a `CGFloat` for that reason, fonts included: a `Font` cannot be
/// interpolated, so the sizes are stored and the fonts built from them.
///
/// Bundling the numbers rather than passing a size class is what makes this
/// tractable. The cast face cards, the drill pane and the credit posters all
/// derive from `contentHeight` and `contentPadding`, so they follow from two
/// values — and the drill animation keeps working untouched because it measures
/// card frames rather than reconstructing them, so both ends move together.
struct PlayerCardMetrics: Equatable {
    var layout: PlayerCardLayout
    /// The height of the card's content — the thumbnail when there is one, and
    /// the columns beside it either way.
    var contentHeight: CGFloat
    /// Padding between the card's content and its glass edge.
    var contentPadding: CGFloat
    /// The gap between the card's columns.
    var columnSpacing: CGFloat
    /// Whether there is room for the 16:9 still.
    ///
    /// The first thing to go when space is short, and not only because it is the
    /// largest single element. It is also the most redundant thing on the card:
    /// the video it depicts is playing at full size directly behind it.
    var showsThumbnail: Bool
    /// Titles: the episode/film name, a person's name.
    var titleSize: CGFloat
    /// Running prose: a synopsis, a biography.
    var bodySize: CGFloat
    /// Supporting detail: the meta row, a character name.
    var captionSize: CGFloat
    /// A cast member's name on their card or row, and the character beneath it.
    var castNameSize: CGFloat
    var castRoleSize: CGFloat
    /// The Info card's action buttons — Restart, Previous, Next, Playback Info.
    var actionSize: CGFloat
    var actionHPadding: CGFloat
    var actionVPadding: CGFloat
    /// Diameter of a cast member's headshot.
    var castHeadshot: CGFloat
    /// The space either side of it, so enlarging the face widens the card rather
    /// than crowding it.
    var castHeadshotSideSpace: CGFloat
    /// The headshot's inset from the top of its card.
    var castVerticalInset: CGFloat
    /// Width of the name-and-biography column in a cast member's detail pane.
    ///
    /// A share of the card rather than a constant: the poster rail beside it
    /// takes whatever is left, and a fixed 900 meant the rail vanished entirely
    /// below that width instead of simply getting shorter.
    var castIdentityWidth: CGFloat
    /// How wide the Info card's text column may run.
    ///
    /// A cap rather than a share, and only a real number on tvOS: prose stops
    /// being readable somewhere around 90 characters however much room there is,
    /// and a 1920pt screen has plenty. Everywhere else the column is free to take
    /// what it is given, because it never gets near that limit.
    var textColumnMaxWidth: CGFloat
    /// How many lines of synopsis the Info card shows.
    var overviewLineLimit: Int
    /// The card's own corner radius.
    ///
    /// Scaled with the card, because a radius is only ever right relative to the
    /// box it rounds: 52 reads as a softly rounded edge on a 240pt band and as a
    /// lozenge on a 152pt one.
    var panelCornerRadius: CGFloat
    /// How much to shrink the capability badges — see `mediaBadgeScale`.
    var badgeScale: CGFloat
    /// In the vertical layout, the height of one cast row.
    var castRowHeight: CGFloat
    /// Everything in a cast member's detail pane that is NOT the biography: the
    /// name above it and the "See more" chip below. Subtracted from the stage to
    /// work out how many lines of life story are left.
    var detailChromeHeight: CGFloat

    var titleFont: Font { .system(size: titleSize, weight: .semibold) }
    var bodyFont: Font { .system(size: bodySize) }
    /// The body's line height, for height budgeting. 1.2× is the system's own
    /// ratio for `.system` faces at these sizes.
    var bodyLineHeight: CGFloat { (bodySize * 1.2).rounded() }
    var captionFont: Font { .system(size: captionSize, weight: .medium) }
    var castNameFont: Font { .system(size: castNameSize, weight: .semibold) }
    var castRoleFont: Font { .system(size: castRoleSize) }
    var actionFont: Font { .system(size: actionSize, weight: .semibold) }

    /// The card's **exact** laid-out height, known up front rather than measured.
    ///
    /// Everything in the horizontal card is pinned to `contentHeight`, so this is
    /// deterministic. `PlayerControls` needs it before the first frame to park the
    /// cluster with the card just off-screen — measuring it instead meant the
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
    /// Whether the card is a tall column rather than a wide band.
    var isVertical: Bool { layout == .vertical }

    /// Across a room, from a remote. The one surface that never resizes, and so
    /// the one preset that is a preset rather than an anchor.
    static let tv = PlayerCardMetrics(
        layout: .horizontal,
        contentHeight: 250,
        contentPadding: 24,
        columnSpacing: 28,
        showsThumbnail: true,
        titleSize: 34,
        bodySize: 25,
        captionSize: 22,
        castNameSize: 21,
        castRoleSize: 18,
        actionSize: 20,
        actionHPadding: 22,
        actionVPadding: 14,
        castHeadshot: 160,
        castHeadshotSideSpace: 31,
        castVerticalInset: 18,
        castIdentityWidth: 900,
        textColumnMaxWidth: 760,
        overviewLineLimit: 4,
        panelCornerRadius: PlozzTheme.Metrics.playerPanelCornerRadius,
        badgeScale: 1,
        castRowHeight: 0,
        detailChromeHeight: 111
    )

    /// The wide end of the horizontal blend: a full-size tablet.
    static let horizontalWide = PlayerCardMetrics(
        layout: .horizontal,
        contentHeight: 208,
        contentPadding: 16,
        columnSpacing: 28,
        showsThumbnail: true,
        titleSize: 34,
        bodySize: 25,
        captionSize: 22,
        castNameSize: 21,
        castRoleSize: 18,
        actionSize: 17,
        actionHPadding: 22,
        actionVPadding: 14,
        castHeadshot: 128,
        castHeadshotSideSpace: 24,
        castVerticalInset: 12,
        castIdentityWidth: 900,
        textColumnMaxWidth: .greatestFiniteMagnitude,
        overviewLineLimit: 4,
        panelCornerRadius: PlozzTheme.Metrics.playerPanelCornerRadius,
        badgeScale: 1,
        castRowHeight: 0,
        detailChromeHeight: 111
    )

    /// The narrow end: a phone on its side.
    ///
    /// Landscape is landscape whatever the device — the video fills the width and
    /// what is left is a short strip along the bottom, which is the shape the
    /// horizontal card was designed for. What a phone lacks is not the proportion
    /// but the size, so this scales the card rather than reorganising it.
    static let horizontalNarrow = PlayerCardMetrics(
        layout: .horizontal,
        contentHeight: 112,
        contentPadding: 12,
        columnSpacing: 14,
        showsThumbnail: true,
        titleSize: 16,
        bodySize: 12,
        captionSize: 11,
        castNameSize: 12,
        castRoleSize: 10,
        actionSize: 13,
        actionHPadding: 12,
        actionVPadding: 9,
        castHeadshot: 52,
        castHeadshotSideSpace: 12,
        castVerticalInset: 8,
        castIdentityWidth: 280,
        textColumnMaxWidth: .greatestFiniteMagnitude,
        overviewLineLimit: 3,
        panelCornerRadius: 20,
        badgeScale: 0.58,
        castRowHeight: 0,
        detailChromeHeight: 58
    )

    /// The narrow end of the vertical blend: a small phone stood up.
    static let verticalNarrow = PlayerCardMetrics(
        layout: .vertical,
        contentHeight: 320,
        contentPadding: 12,
        columnSpacing: 12,
        showsThumbnail: false,
        titleSize: 16,
        bodySize: 13,
        captionSize: 11,
        castNameSize: 14,
        castRoleSize: 12,
        actionSize: 13,
        actionHPadding: 12,
        actionVPadding: 9,
        castHeadshot: 40,
        castHeadshotSideSpace: 12,
        castVerticalInset: 8,
        castIdentityWidth: 280,
        textColumnMaxWidth: .greatestFiniteMagnitude,
        overviewLineLimit: 4,
        // A radius is only right relative to the box it rounds; 52 on a card this
        // narrow reads as a lozenge.
        panelCornerRadius: 20,
        badgeScale: 0.58,
        castRowHeight: 58,
        detailChromeHeight: 58
    )

    /// The wide end of the vertical blend: a tablet in portrait, or a half-width
    /// window on a large one.
    static let verticalWide = PlayerCardMetrics(
        layout: .vertical,
        contentHeight: 480,
        contentPadding: 18,
        columnSpacing: 16,
        showsThumbnail: false,
        titleSize: 24,
        bodySize: 17,
        captionSize: 14,
        castNameSize: 18,
        castRoleSize: 15,
        actionSize: 16,
        actionHPadding: 18,
        actionVPadding: 12,
        castHeadshot: 56,
        castHeadshotSideSpace: 16,
        castVerticalInset: 10,
        castIdentityWidth: 520,
        textColumnMaxWidth: .greatestFiniteMagnitude,
        overviewLineLimit: 6,
        panelCornerRadius: 30,
        badgeScale: 0.78,
        castRowHeight: 76,
        detailChromeHeight: 84
    )

    #if os(tvOS)
    static let platformDefault = tv
    #else
    static let platformDefault = horizontalWide
    #endif

    /// The widths the horizontal anchors describe. Below the first the card is
    /// drawn at its narrow size, above the second at its full one, and in between
    /// it is blended — there is no width at which it jumps.
    private static let horizontalBlend: ClosedRange<CGFloat> = 640...1180
    /// The same for the vertical card, across the phone-to-tablet span.
    private static let verticalBlend: ClosedRange<CGFloat> = 360...820

    /// Everything stacked above the card: the title row, the scrub row, the tab
    /// strip and the padding around them.
    ///
    /// Subtracted rather than taken as a fraction, because it is a fixed stack of
    /// controls — a share would hand a tall screen a card that grew right through
    /// them.
    private static let chromeHeight: CGFloat = 260
    /// The most of the screen a horizontal card may cover. It sits over the video
    /// rather than beside it, so this is the ceiling that keeps the film visible.
    private static let horizontalHeightShare: CGFloat = 0.42

    /// Pick the metrics for the space the card has actually been given.
    ///
    /// Shape first, then size. Landscape gets the horizontal band whatever the
    /// device; portrait gets the column — unless it is wide enough for the band
    /// anyway, as a tablet in portrait is. This is the split Apple's own player
    /// makes, and it is why a phone on its side should look like an iPad rather
    /// than like a phone.
    static func resolved(forWidth width: CGFloat, height: CGFloat) -> PlayerCardMetrics {
        #if os(tvOS)
        return .tv
        #else
        // Zero on the very first pass, before the geometry reader has reported.
        // Assume the roomy layout rather than the cramped one: a card that starts
        // full and stays full is the common case, and guessing narrow would make
        // every iPad open with a visible re-layout.
        guard width > 0, height > 0 else { return .horizontalWide }

        if width > height || width >= horizontalBlend.upperBound {
            var metrics = interpolate(
                from: horizontalNarrow,
                to: horizontalWide,
                at: progress(width, in: horizontalBlend)
            )
            // Height has the final say. The blend answers "how big should this
            // card be for its width", which on a short landscape screen can still
            // be more than there is room for.
            let ceiling = height * horizontalHeightShare - metrics.contentPadding * 2
            metrics.contentHeight = max(min(metrics.contentHeight, ceiling), 96).rounded()
            metrics.castIdentityWidth = identityWidth(forCardWidth: width, metrics: metrics)
            return metrics
        }

        var metrics = interpolate(
            from: verticalNarrow,
            to: verticalWide,
            at: progress(width, in: verticalBlend)
        )
        let available = height - chromeHeight - metrics.contentPadding * 2
        metrics.contentHeight = max(min(metrics.contentHeight, available), 160).rounded()
        metrics.castIdentityWidth = identityWidth(forCardWidth: width, metrics: metrics)
        return metrics
        #endif
    }

    /// Where `value` sits across `range`, as 0…1.
    private static func progress(_ value: CGFloat, in range: ClosedRange<CGFloat>) -> CGFloat {
        guard range.upperBound > range.lowerBound else { return 1 }
        return min(max((value - range.lowerBound) / (range.upperBound - range.lowerBound), 0), 1)
    }

    /// The identity column's share of the card, so the poster rail beside it gets
    /// the rest. Floored so a name and a line of prose always have somewhere to
    /// go, and capped so the rail is not pushed off a very wide card.
    private static func identityWidth(
        forCardWidth width: CGFloat,
        metrics: PlayerCardMetrics
    ) -> CGFloat {
        let usable = width - metrics.contentPadding * 2
        return min(max((usable * 0.46).rounded(), 240), 900)
    }

    /// Blend every measurement between two anchors.
    ///
    /// Deliberately exhaustive: a value left out would snap between two sizes
    /// while everything around it slid, which is more obviously broken than the
    /// stepped layout this replaced. `layout` and `showsThumbnail` are the two
    /// that cannot be blended — they are structure, not size — and both anchors
    /// of a given pair agree on them, so taking either is safe.
    private static func interpolate(
        from narrow: PlayerCardMetrics,
        to wide: PlayerCardMetrics,
        at t: CGFloat
    ) -> PlayerCardMetrics {
        func lerp(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
            // `.greatestFiniteMagnitude` stands in for "no limit" and must not be
            // dragged into a finite number by the blend.
            guard a.isFinite, b.isFinite,
                  a < .greatestFiniteMagnitude, b < .greatestFiniteMagnitude else {
                return t < 1 ? a : b
            }
            return a + (b - a) * t
        }
        return PlayerCardMetrics(
            layout: wide.layout,
            contentHeight: lerp(narrow.contentHeight, wide.contentHeight),
            contentPadding: lerp(narrow.contentPadding, wide.contentPadding).rounded(),
            columnSpacing: lerp(narrow.columnSpacing, wide.columnSpacing).rounded(),
            showsThumbnail: wide.showsThumbnail,
            titleSize: lerp(narrow.titleSize, wide.titleSize).rounded(),
            bodySize: lerp(narrow.bodySize, wide.bodySize).rounded(),
            captionSize: lerp(narrow.captionSize, wide.captionSize).rounded(),
            castNameSize: lerp(narrow.castNameSize, wide.castNameSize).rounded(),
            castRoleSize: lerp(narrow.castRoleSize, wide.castRoleSize).rounded(),
            actionSize: lerp(narrow.actionSize, wide.actionSize).rounded(),
            actionHPadding: lerp(narrow.actionHPadding, wide.actionHPadding).rounded(),
            actionVPadding: lerp(narrow.actionVPadding, wide.actionVPadding).rounded(),
            castHeadshot: lerp(narrow.castHeadshot, wide.castHeadshot).rounded(),
            castHeadshotSideSpace: lerp(narrow.castHeadshotSideSpace, wide.castHeadshotSideSpace).rounded(),
            castVerticalInset: lerp(narrow.castVerticalInset, wide.castVerticalInset).rounded(),
            castIdentityWidth: lerp(narrow.castIdentityWidth, wide.castIdentityWidth).rounded(),
            textColumnMaxWidth: lerp(narrow.textColumnMaxWidth, wide.textColumnMaxWidth),
            overviewLineLimit: Int(lerp(
                CGFloat(narrow.overviewLineLimit),
                CGFloat(wide.overviewLineLimit)
            ).rounded()),
            panelCornerRadius: lerp(narrow.panelCornerRadius, wide.panelCornerRadius).rounded(),
            badgeScale: lerp(narrow.badgeScale, wide.badgeScale),
            castRowHeight: lerp(narrow.castRowHeight, wide.castRowHeight).rounded(),
            detailChromeHeight: lerp(narrow.detailChromeHeight, wide.detailChromeHeight).rounded()
        )
    }
}

/// Pins the card's height — in the horizontal layout only.
///
/// The horizontal card promises an exact height, because tvOS parks the
/// transport by it before the first frame: measuring it instead meant the parked
/// offset moved the moment the measurement landed, which showed as the transport
/// jumping.
///
/// A vertical card is deliberately left alone. It holds content whose length is
/// not known up front, and `frame(maxHeight:)` is not the tool for that — it
/// **expands to fill** the proposal, exactly as `frame(maxWidth: .infinity)`
/// does, so capping a card with it produced a full-height sheet of glass with the
/// content stranded inside. Vertical cards size themselves, via
/// ``SwiftUI/View/playerCardNaturalHeight(cap:natural:)`` or an explicit height.
struct PlayerCardHeight: ViewModifier {
    let metrics: PlayerCardMetrics

    func body(content: Content) -> some View {
        if metrics.isVertical {
            content
        } else {
            content.frame(height: metrics.cardHeight)
        }
    }
}

private struct PlayerCardNaturalHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension View {
    /// Size this card to its content, up to `cap`.
    ///
    /// `frame(maxHeight:)` cannot do this on its own: it expands to fill the
    /// proposal, so a three-line synopsis produced a card as tall as its ceiling.
    /// Nor can `fixedSize`, which proposes `nil` — under an unconstrained
    /// proposal a `ViewThatFits` always picks its first, non-scrolling branch, so
    /// a long synopsis would be clipped rather than scrolled.
    ///
    /// So the natural height is measured from a hidden copy laid out at its ideal
    /// size, and the real card is given `min(natural, cap)`. The hidden copy must
    /// be the NON-scrolling content: a `ScrollView` has no ideal height to report.
    /// There is no layout cycle — the copy's height comes from `fixedSize` and its
    /// width from the parent, neither of which depends on the result.
    func playerCardNaturalHeight<Natural: View>(
        cap: CGFloat,
        @ViewBuilder natural: @escaping () -> Natural
    ) -> some View {
        modifier(PlayerCardNaturalHeight(cap: cap, natural: natural))
    }
}

private struct PlayerCardNaturalHeight<Natural: View>: ViewModifier {
    let cap: CGFloat
    @ViewBuilder let natural: () -> Natural
    @State private var measured: CGFloat = 0

    func body(content: Content) -> some View {
        content
            // `nil` until the first measurement lands, so the card takes its own
            // shape for one frame rather than collapsing to zero and popping.
            .frame(height: measured > 0 ? min(measured, cap) : nil, alignment: .top)
            .background(alignment: .top) {
                natural()
                    .hidden()
                    .fixedSize(horizontal: false, vertical: true)
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(
                                key: PlayerCardNaturalHeightKey.self,
                                value: geometry.size.height
                            )
                        }
                    }
            }
            // Applied WITHOUT animation, deliberately.
            //
            // The measurement lands a frame after the card appears, so animating
            // it moved the tab strip a second time — once with the card's own
            // transition and again when the height arrived, on a different
            // transaction and therefore at a different rate. Instant here means
            // the only thing the viewer sees is the card opening.
            .onPreferenceChange(PlayerCardNaturalHeightKey.self) { height in
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { measured = height }
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
    /// threading a parameter through each of them would put the number in a dozen
    /// initialisers that have no other reason to know about it.
    var playerCardMetrics: PlayerCardMetrics {
        get { self[PlayerCardMetricsKey.self] }
        set { self[PlayerCardMetricsKey.self] = newValue }
    }
}
#endif
