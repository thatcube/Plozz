#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// A horizontally-scrolling, focusable row of media cards with a title.
/// Reused by Home (Continue Watching, Latest) and detail (episodes, related).
/// The one definition of a rail heading's type.
///
/// Shared so a skeleton standing in for a rail can reserve exactly the height the
/// real heading will take. A placeholder that guesses is a placeholder that
/// shifts the page when the content lands.
public enum PlozzRailTitle {
    /// The platform's own section header, not a tvOS size shrunk down.
    /// `sectionHeaderFontSize` is tuned for a screen read across a room and takes
    /// no account of Dynamic Type; `.title2` is what every other iOS surface in
    /// this app titles a rail with, and it scales with the user's text size.
    public static func font(sectionHeaderFontSize: CGFloat) -> Font {
        #if os(tvOS)
        return .system(size: sectionHeaderFontSize, weight: .bold)
        #else
        return .title2.bold()
        #endif
    }
}

public struct MediaRowView: View {
    public enum Presentation: Equatable, Sendable {
        case poster
        case landscape
        case episodeColumn
    }

    /// Pre-built: a row heading is either a row-kind name (copy) or a library
    /// name (provider content), and only the caller knows which. `nil` renders no
    /// heading (previously spelled as an empty string).
    private let title: Text?
    /// Row contents, guaranteed to hold each `id` once.
    ///
    /// `ForEach` over `Identifiable` requires unique ids; duplicates are
    /// undefined behaviour and render as a blank slot where a card should be —
    /// the row reserves space for the repeat and then draws nothing in it.
    ///
    /// This is reachable in normal use, not a theoretical guard. Two media shares
    /// can point at the *same* storage — the same server over NFS and over SMB,
    /// say — and identical relative paths then produce identical catalog ids.
    /// Cross-server merging unions by external identity (TMDb and the like), so
    /// until enrichment has supplied those ids it has nothing to match on and
    /// both copies survive into the row.
    private let items: [MediaItem]
    private let presentation: Presentation
    private let spoilerSettings: SpoilerSettings
    /// Identify each card by its show — the show's artwork with its logo over it
    /// — rather than by the item's own thumbnail. Continue Watching opts in.
    private let showsSeriesArtwork: Bool
    /// When set, the row scrolls to and moves focus onto the matching item the
    /// first time it appears (used by series/season detail to surface the
    /// "next up" episode). `nil` keeps the platform's default focus behaviour.
    private let initialFocusID: String?
    /// When set, the row scrolls so the matching item is leading-aligned the first
    /// time it appears, **without** moving focus onto it. Used when focus should
    /// stay elsewhere (e.g. the hero's Play button) while the row is still
    /// pre-positioned at a chosen episode. Ignored when `initialFocusID` is set.
    private let initialScrollID: String?
    /// When set, the matching item becomes the row's *default focus* — the card
    /// focus lands on when focus first moves **into** the row from outside (e.g.
    /// pressing down from the hero Play button), regardless of which card is
    /// geometrically nearest. Used so the episode the Play button resumes is the
    /// one focused on entry, even when it's far down a long season.
    private let defaultFocusID: String?
    /// Bumped by the parent whenever focus moves to a sibling control *above* the
    /// row (e.g. the season tab bar). This is the deterministic signal that focus
    /// has genuinely left the row, so the entry gate re-arms *only* here — never by
    /// inferring "focus left" from a transient `nil`, which a fast horizontal hold
    /// produces constantly (the focused card is recycled between frames) and which
    /// would otherwise disable cards mid-browse and strand the focus indicator.
    private let focusResetToken: Int
    /// Bumped to actively move focus back onto this row's gate target (the card
    /// focus was last on). Used when returning from a pushed page: tvOS restores
    /// focus by geometry and can land anywhere, so the row has to reclaim it
    /// rather than merely re-arm its entry gate.
    /// Whether another page is currently covering this row's page. On the way in
    /// the row snapshots the card focus was on; on the way out it restores focus
    /// to that snapshot, because tvOS hands focus to the page's hero instead and
    /// can overwrite the row's live memory in the process.
    private let isCovered: Bool
    /// Called once the row has finished reclaiming focus, so the caller can stop
    /// suppressing the side effects of the system's own focus moves.
    private let onRefocusComplete: (() -> Void)?
    /// Leading inset for the row's title and first card. Defaults to the standard
    /// screen padding (Home rows); detail pages pass the larger hero leading
    /// padding so the row aligns with the hero text above it.
    private let leadingInset: CGFloat
    /// How far the navigation chrome insets page content. Added to `leadingInset`
    /// so the row's FIRST card clears the rail, while the scroll viewport still
    /// spans the full width — which is what lets cards scroll *under* the rail and
    /// fade out there instead of being cut off at a narrowed viewport edge.
    @Environment(\.plozzNavigationContentInset) private var navigationContentInset
    /// Keeps branch-specific masking completely out of native navigation styles.
    @Environment(\.plozzPinnedSidebarActive) private var pinnedSidebarActive

    /// Extra scroll margin beyond the fade, so a FOCUSED card — which grows
    /// outward past its layout frame — still parks entirely clear of the feather.
    /// Parking a card exactly at the fade's end looks correct at rest and clipped
    /// the moment it takes focus, which is the symptom this exists to prevent.
    private var focusLiftAllowance: CGFloat { 28 }
    private let onSelect: (MediaItem) -> Void
    /// When `true`, selecting a card starts playback immediately, so its cards
    /// show the resume chip (play glyph + progress bar + time). Threaded to
    /// `PosterCardView.playsOnSelect`.
    private let playsOnSelect: Bool
    /// Called whenever focus moves onto a card (with that item). Used by series
    /// detail to mirror the focused episode into the page hero. When set, every
    /// card becomes individually focus-tracked.
    private let onFocusChange: ((MediaItem?) -> Void)?
    /// Fires synchronously when focus reaches any card in the row. Unlike
    /// `onFocusChange`, this is not settle-debounced and is intended for lightweight
    /// cosmetic state such as the series hero recede.
    private let onFocusEntered: (() -> Void)?
    /// Optional localized cue drawn on selected card kinds (e.g. a Related row
    /// marks sequels/spin-offs as "Continues"). The row owns card construction,
    /// so callers need this seam rather than rebuilding the whole rail.
    private let statusCue: ((MediaItem) -> LocalizedStringResource?)?
    /// Stable lookup tables so focus/prefetch hot paths avoid repeated linear scans.
    private let itemIDSet: Set<String>
    private let itemIndexByID: [String: Int]
    private let itemByID: [String: MediaItem]

    @FocusState private var focusedID: String?
    @Environment(\.plozzMetrics) private var metrics
    @State private var didApplyInitialFocus = false
    /// Whether focus currently sits inside this row. While `false` and a gate
    /// target is set, the first card focus lands on (whatever tvOS picks
    /// geometrically) is overridden by moving focus to the target. It is re-armed
    /// when focus genuinely leaves the row (signalled by `focusResetToken`, e.g.
    /// going up to the season bar) and when the supplied `defaultFocusID` changes
    /// (e.g. season swap) — never from a transient mid-scroll `nil`.
    @State private var focusEngaged = false
    /// Card ids currently realised in the lazy stack. Used to avoid redundant
    /// `scrollTo` work that can cause visible snap/jump when the target is already
    /// on screen.
    @State private var visibleIDs: Set<String> = []
    /// Coalesces focus-change reporting to `onFocusChange` (the page hero). Holding
    /// RIGHT moves focus through many cards per second; without coalescing the hero
    /// would fully rebuild + cross-fade on each one, stuttering the scroll. We defer
    /// the report a beat and only fire for the card focus actually settles on.
    @State private var pendingReport: DispatchWorkItem?
    /// The card focus last settled on inside this row, remembered after focus
    /// leaves so the gate re-targets where the user actually was — not the
    /// came-in/resume episode. A stale id from another season is ignored because it
    /// won't exist in the current `items`.
    @State private var lastFocusedID: String?
    /// Whether the user has actually moved around this row since its target was
    /// last re-pointed. Latches the entry gate off — see `cardIsDisabled`.
    @State private var hasBrowsedSinceTargetChange = false
    /// Items whose artwork has already been queued during the current directional
    /// traversal. Cleared when direction reverses because a long row can evict the
    /// outbound posters before the viewer comes back.
    @State private var prefetchedIDs: Set<String> = []
    @State private var prefetchedPreviewIDs: Set<String> = []
    @State private var lastArtworkPrefetchIndex: Int?
    @State private var artworkPrefetchDirection = 1
    @State private var artworkPrefetchTasks = ArtworkPrefetchTasks()
    /// Cards whose detail-hero backdrop has been warmed — see `prefetchHeroPreview`.
    @State private var prefetchedHeroIDs: Set<String> = []
    /// The card focus was on when this row's page was covered — see `isCovered`.
    @State private var coveredFocusID: String?

    public init(
        title: Text?,
        items: [MediaItem],
        style: PosterCardView.Style = .poster,
        spoilerSettings: SpoilerSettings = .default,
        showsSeriesArtwork: Bool = false,
        initialFocusID: String? = nil,
        initialScrollID: String? = nil,
        defaultFocusID: String? = nil,
        focusResetToken: Int = 0,
        isCovered: Bool = false,
        onRefocusComplete: (() -> Void)? = nil,
        leadingInset: CGFloat = PlozzTheme.Metrics.screenPadding,
        onFocusEntered: (() -> Void)? = nil,
        onFocusChange: ((MediaItem?) -> Void)? = nil,
        statusCue: ((MediaItem) -> LocalizedStringResource?)? = nil,
        playsOnSelect: Bool = false,
        onSelect: @escaping (MediaItem) -> Void
    ) {
        self.init(
            title: title,
            items: items,
            presentation: style == .poster ? .poster : .landscape,
            spoilerSettings: spoilerSettings,
            showsSeriesArtwork: showsSeriesArtwork,
            initialFocusID: initialFocusID,
            initialScrollID: initialScrollID,
            defaultFocusID: defaultFocusID,
            focusResetToken: focusResetToken,
            isCovered: isCovered,
            onRefocusComplete: onRefocusComplete,
            leadingInset: leadingInset,
            onFocusEntered: onFocusEntered,
            onFocusChange: onFocusChange,
            statusCue: statusCue,
            playsOnSelect: playsOnSelect,
            onSelect: onSelect
        )
    }

    public init(
        title: Text?,
        items: [MediaItem],
        presentation: Presentation,
        spoilerSettings: SpoilerSettings = .default,
        showsSeriesArtwork: Bool = false,
        initialFocusID: String? = nil,
        initialScrollID: String? = nil,
        defaultFocusID: String? = nil,
        focusResetToken: Int = 0,
        isCovered: Bool = false,
        onRefocusComplete: (() -> Void)? = nil,
        leadingInset: CGFloat = PlozzTheme.Metrics.screenPadding,
        onFocusEntered: (() -> Void)? = nil,
        onFocusChange: ((MediaItem?) -> Void)? = nil,
        statusCue: ((MediaItem) -> LocalizedStringResource?)? = nil,
        playsOnSelect: Bool = false,
        onSelect: @escaping (MediaItem) -> Void
    ) {
        self.title = title
        let uniqueItems = Self.uniqued(items)
        self.items = uniqueItems
        self.presentation = presentation
        self.spoilerSettings = spoilerSettings
        self.showsSeriesArtwork = showsSeriesArtwork
        self.initialFocusID = Self.presentationID(
            matching: initialFocusID,
            in: uniqueItems
        )
        self.initialScrollID = Self.presentationID(
            matching: initialScrollID,
            in: uniqueItems
        )
        self.defaultFocusID = Self.presentationID(
            matching: defaultFocusID,
            in: uniqueItems
        )
        self.focusResetToken = focusResetToken
        self.isCovered = isCovered
        self.onRefocusComplete = onRefocusComplete
        self.leadingInset = leadingInset
        self.onFocusEntered = onFocusEntered
        self.onFocusChange = onFocusChange
        self.statusCue = statusCue
        self.playsOnSelect = playsOnSelect
        self.onSelect = onSelect
        // Every derived table is built from the DEDUPED array, never from the
        // caller's. Building them from the original left indices pointing at
        // pre-collapse offsets — with [A, A, B], B rendered at 1 but was recorded
        // at 2, which aborted artwork prefetch — and `byID` holding the *discarded*
        // duplicate, so focusing the surviving card reported the wrong item.
        self.itemIDSet = Set(uniqueItems.map(\.stablePresentationID))
        var indexByID: [String: Int] = [:]
        var byID: [String: MediaItem] = [:]
        for (offset, item) in uniqueItems.enumerated() {
            indexByID[item.stablePresentationID] = offset
            byID[item.stablePresentationID] = item
        }
        self.itemIndexByID = indexByID
        self.itemByID = byID
    }

    /// Whether each card needs an individual focus binding installed — required
    /// to drive initial/default focus and to report focus changes to the hero.
    private var tracksFocus: Bool {
        MediaRowFocusPolicy.observesFocus(
            initialFocusID: initialFocusID,
            defaultFocusID: defaultFocusID,
            hasOnFocusEntered: onFocusEntered != nil,
            hasOnFocusChange: onFocusChange != nil
        )
    }

    /// Focus observation and directional entry gating are separate concerns.
    /// A callback-only row needs per-card bindings, but must retain tvOS's normal
    /// column-aligned navigation rather than becoming a remembered focus section.
    private var usesFocusEntryGate: Bool {
        MediaRowFocusPolicy.usesEntryGate(defaultFocusID: defaultFocusID)
    }

    /// The card the entry gate targets: the card focus last settled on in this row
    /// once the user has browsed (`lastFocusedID`), otherwise the externally
    /// supplied `defaultFocusID` (the resume/came-in episode). This is what makes
    /// re-entry land on the episode you were last looking at, not the one you
    /// arrived on. A stale `lastFocusedID` from another season is ignored because
    /// it won't be present in the current `items`.
    private var gateTarget: String? {
        guard usesFocusEntryGate else { return nil }
        if let lastFocusedID, itemIDSet.contains(lastFocusedID) {
            return lastFocusedID
        }
        guard let defaultFocusID, itemIDSet.contains(defaultFocusID) else { return nil }
        return defaultFocusID
    }

    /// Whether the row restricts entry focus to a single target card — only when a
    /// `gateTarget` is set *and* it exists in the row. We keep that card scrolled
    /// into view whenever the row isn't engaged (see `handleFocusChange` /
    /// `onChange(of: defaultFocusID)`), so it's always realised in the lazy stack
    /// and the row never becomes unreachable while the others are disabled.
    private var gatesFocus: Bool {
        guard let gateTarget else { return false }
        return itemIDSet.contains(gateTarget)
    }

    /// While the row is gated and not yet engaged, every card *except* the target
    /// is removed from the focus system, so focus entering the row can only ever
    /// land on the target — no transient highlight on the geometrically-nearest
    /// card. `PosterCardView` ignores `isEnabled`, so this affects focusability
    /// only, never appearance.
    private func cardIsDisabled(_ item: MediaItem) -> Bool {
        // While the page is covered, the only focusable card is the one focus
        // will be restored to. The system re-establishes focus by geometry as
        // the page reappears, and leaving the other cards focusable let it land
        // on one of them (or the row below) visibly before we corrected it.
        if let coveredFocusID {
            return item.stablePresentationID != coveredFocusID
        }
        // The gate stops disabling cards for good once the row has been browsed.
        //
        // Disabling exists ONLY to avoid a transient highlight on the
        // geometrically-nearest card as focus enters the row; the real targeting
        // is `handleFocusChange` redirecting to `gateTarget`, which still runs on
        // every re-entry. So the cost of dropping it is cosmetic, and the cost of
        // keeping it turned out not to be.
        //
        // Keying it on `focusEngaged` was the bug. That flag is reset by
        // `focusResetToken`, which the page bumps on season-bar and hero focus
        // events — and during a fast horizontal hold `focusedID` blips to nil
        // between cards (see `handleFocusChange`). A bump landing in one of those
        // blips disabled every card but the target WHILE THE USER WAS BROWSING:
        // tvOS lost its focus candidate, scrambled for focusable content, and the
        // lazy stack realised from the beginning. Measured on device: holding LEFT
        // from #114 walked to #109, then the row teleported to #0...#4 and the
        // gate dragged it back — the "bounce".
        //
        // `hasBrowsedSinceTargetChange` only ever resets at the discrete moments
        // the row is genuinely re-entered from scratch (a new `defaultFocusID`,
        // i.e. season switch or open), so no token churn can revive the gate
        // under the user.
        return gatesFocus
            && !focusEngaged
            && !hasBrowsedSinceTargetChange
            && item.stablePresentationID != gateTarget
    }

    /// First occurrence wins, order otherwise preserved: callers have already
    /// sorted these (Recently Added by date, Continue Watching by progress), so
    /// the survivor must be the one the ordering chose.
    static func uniqued(_ items: [MediaItem]) -> [MediaItem] {
        var seen = Set<String>()
        return items.filter {
            seen.insert($0.stablePresentationID).inserted
        }
    }

    static func presentationID(
        matching suppliedID: String?,
        in items: [MediaItem]
    ) -> String? {
        guard let suppliedID else { return nil }
        return items.first {
            $0.stablePresentationID == suppliedID || $0.id == suppliedID
        }?.stablePresentationID ?? suppliedID
    }

    public var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: layoutMetrics.sectionTitleSpacing) {
                if let title {
                    title
                        .font(PlozzRailTitle.font(
                            sectionHeaderFontSize: layoutMetrics.sectionHeaderFontSize
                        ))
                        .padding(.leading, leadingInset + navigationContentInset)
                }

                PinnedSidebarLeadingFade(
                    isActive: pinnedSidebarActive,
                    inset: navigationContentInset,
                    verticalOverhang: layoutMetrics.railShadowClearance
                ) {
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: layoutMetrics.cardSpacing) {
                            ForEach(items, id: \.stablePresentationID) { item in
                                tappableCard(for: item)
                            }
                        }
                        // The row's ordinary page gutter, unchanged from before the
                        // navigation rail existed.
                        .padding(.leading, leadingInset)
                        .padding(.trailing, PlozzTheme.Metrics.screenPadding)
                        // Reserve generous vertical room *inside* the clip so a
                        // focused card's lift + drop shadow are never cut. The
                        // negative outer padding below cancels this clearance in
                        // layout, so the row's height and its gap to the neighbouring
                        // rows are unchanged; only the drawing area grows.
                        .padding(.vertical, layoutMetrics.railShadowClearance)
                    }
                    .padding(.top, layoutMetrics.railTopClearanceOffset)
                    .padding(.bottom, layoutMetrics.railBottomClearanceOffset)
                    // The navigation gutter is the scroll view's SAFE AREA — the
                    // same mechanism that lets a row scroll under the system tab bar
                    // on tvOS, and the reason that has never needed any of this.
                    //
                    // A safe area is the one inset the focus engine parks a focused
                    // card against, while the viewport stays full width so the card
                    // still DRAWS in the gutter on its way past and can be feathered
                    // there. Padding inside the stack scrolls away; `contentMargins`
                    // is ignored by focus scrolling (only the first card landed);
                    // insetting the viewport puts the gutter outside the scroll view
                    // entirely, so it either hard-cuts or the engine scrolls cards
                    // back in. The safe area is the only one that does all three.
                    // Section the whole rail VIEWPORT (the full-width horizontal
                    // ScrollView) — NOT the scrolled inner LazyHStack — but ONLY for
                    // the gated single-target flow (the episode rail). tvOS only enters
                    // a focus section if part of its FRAME sits in the swipe's path, and
                    // then forwards focus to the section's sole enabled focusable
                    // regardless of where that card is scrolled. On the inner LazyHStack
                    // the section only spanned the scrolled/visible cards, so pressing
                    // DOWN from a horizontally-distant season chip found no rail geometry
                    // in its corridor and either missed the target (landing on the cast
                    // avatar below) or didn't move at all when the target was scrolled to
                    // the opposite side. At the ScrollView level the section is the full,
                    // static viewport width — directly below the season bar for every
                    // chip position — so DOWN reliably reaches the gated target wherever
                    // it sits (last far-right, first far-left, or middle), with no
                    // repositioning. This mirrors the season bar's own ScrollView-level
                    // `.focusSection()` (which makes UP work the same way) and the hero
                    // action row (commit eddd937e). Ordinary rows (Home, detail children —
                    // `gatesFocus == false`) stay UNsectioned so vertical navigation
                    // keeps tvOS's column-aligned X-projection (the "focus jumps to the
                    // opposite side" bug, commit f812fe64).
                    .focusSectionIf(gatesFocus)
                    .onAppear { applyInitialFocus(using: proxy) }
                    // The opening alignment usually CAN'T run on first layout: a
                    // season page loads its episodes asynchronously, so `onAppear`
                    // fires with an empty row and the target not yet in `itemIDSet`.
                    // Retry when the items land, otherwise the row simply opens
                    // un-aligned and the target only snaps into place much later,
                    // when focus leaves and the re-entry scroll runs.
                    .onChange(of: itemIDSet) { _, _ in
                        applyInitialFocus(using: proxy)
                    }
                    .onChange(of: focusedID) { _, newValue in
                        handleFocusChange(to: newValue, using: proxy)
                    }
                    .onChange(of: defaultFocusID) { _, newTarget in
                        // The supplied target changed (e.g. switching seasons). Drop
                        // any remembered focus from the previous set, re-arm the gate,
                        // and bring the new target into view so it's realised and is
                        // the only focusable card on the next entry.
                        focusEngaged = false
                        lastFocusedID = nil
                        hasBrowsedSinceTargetChange = false
                        guard let newTarget, itemIDSet.contains(newTarget) else { return }
                        // Hard-align rather than going through `scrollToIfNeeded`.
                        // The caller only re-points this at discrete moments — open,
                        // season change, cross-server switch — never while browsing,
                        // so there is no snap to protect against here. The "already
                        // visible, skip it" shortcut actively breaks these cases: the
                        // lazy stack has usually "appeared" the target already, off to
                        // the right, so the row would open (or switch seasons) with the
                        // episode stranded mid-row instead of leading.
                        didApplyInitialFocus = true
                        scrollToInitialPosition(newTarget, using: proxy)
                    }
                    .onChange(of: isCovered) { _, covered in
                        guard covered else {
                            reclaimFocusAfterCovering(using: proxy)
                            return
                        }
                        // Snapshot on the way IN. Reading the live value on the
                        // way out is too late: the system's own focus moves can
                        // land on another card first and overwrite it.
                        coveredFocusID = focusEngaged ? lastFocusedID : nil
                    }
                    // Does the ITEMS ARRAY change mid-browse? If it does, the
                    // LazyHStack rebuilds and the scroll offset resets to the
                    // start — which would explain the row teleporting to #0
                    // without any scroll call of ours.
                    .onChange(of: items.count) { old, new in
                    }
                    .onChange(of: itemIDSet) { _, _ in
                    }
                    .onChange(of: focusResetToken) { _, _ in
                        // Focus genuinely left the row for a sibling above (the season
                        // bar told us). Re-arm the entry gate so the next down-press
                        // lands on the episode you were last on (`lastFocusedID`, kept
                        // so re-entry returns there — not the came-in episode), and
                        // make sure it's realised/in view for the gate to target.
                        focusEngaged = false
                        if let target = gateTarget { scrollToIfNeeded(target, using: proxy) }
                    }
                }
                .onDisappear {
                    pendingReport?.cancel()
                    pendingReport = nil
                    artworkPrefetchTasks.cancelAll()
                    prefetchedIDs.removeAll(keepingCapacity: true)
                    prefetchedPreviewIDs.removeAll(keepingCapacity: true)
                    lastArtworkPrefetchIndex = nil
                }
            }
        }
    }

    /// The card, plus whatever it takes to select it on this platform.
    ///
    /// tvOS drives selection through the card's own `.focusable` + tap, which
    /// `focusableCard` installs — deliberately not a `Button`, because a Button
    /// paints the system focus platter behind it. That branch does nothing off
    /// tvOS, though: it applies a content shape and no gesture, because every
    /// other iOS surface wraps its cards in a `NavigationLink` and supplies the
    /// tap that way. This row does not — it takes an `onSelect` closure — so its
    /// cards did nothing at all when tapped.
    ///
    /// Wrapped HERE rather than fixed in `focusableCard`, which those
    /// NavigationLink surfaces also use: a tap gesture added there would sit
    /// inside the link's label and could swallow the link's own tap.
    @ViewBuilder
    private func tappableCard(for item: MediaItem) -> some View {
        #if os(tvOS)
        card(for: item)
        #else
        Button { onSelect(item) } label: { card(for: item) }
            // Plain, so the card keeps its own colours and chrome.
            .buttonStyle(.plain)
        #endif
    }

    @ViewBuilder
    private func card(for item: MediaItem) -> some View {
        switch presentation {
        case .poster:
            trackedCard(
                PosterCardView(
                    item: item,
                    style: .poster,
                    spoilerSettings: spoilerSettings,
                    showsSeriesArtwork: showsSeriesArtwork,
                    statusCue: statusCue?(item),
                    playsOnSelect: playsOnSelect
                ) { onSelect(item) },
                for: item
            )
        case .landscape:
            trackedCard(
                PosterCardView(
                    item: item,
                    style: .landscape,
                    spoilerSettings: spoilerSettings,
                    showsSeriesArtwork: showsSeriesArtwork,
                    statusCue: statusCue?(item),
                    playsOnSelect: playsOnSelect
                ) { onSelect(item) },
                for: item
            )
        case .episodeColumn:
            trackedCard(
                EpisodeColumnCard(
                    item: item,
                    spoilerSettings: spoilerSettings
                ) { onSelect(item) }
                // Skips the body when the card's inputs are unchanged. Without
                // it the stored `action` closure makes every card compare
                // unequal, so the whole rail re-rendered on each parent update.
                .equatable()
                .environment(\.plozzMetrics, .standard),
                for: item
            )
        }
    }

    @ViewBuilder
    private func trackedCard<Card: View>(_ content: Card, for item: MediaItem) -> some View {
        // Pin every card to its true rendered width so a `LazyHStack` can compute
        // the offset of a far-off initial-focus target (e.g. episode 132 of a long
        // season) without first realising every card in between — which is what
        // made focusing the "next up" episode lag on huge seasons.
        //
        // The pinned width must equal the card's *glass surface* width, not just
        // its artwork width, or the layout slot is narrower than what's drawn and
        // the surfaces overhang into the inter-card gap. A poster's artwork is
        // flexible, so its glass equals `posterWidth`. A landscape card's artwork
        // is fixed and sits inside a `cardInset` glass margin, so its glass
        // is `landscapeWidth + 2 * cardInset` — pin to that so `cardSpacing`
        // is a real gap and adjacent cards never overlap at rest.
        let card = content
            .frame(width: cardSlotWidth)
            .id(item.stablePresentationID)
            .onAppear {
                visibleIDs.insert(item.stablePresentationID)
                prefetchArtwork(around: item)
            }
            .onDisappear {
                visibleIDs.remove(item.stablePresentationID)
            }
        if tracksFocus {
            card
                .focused($focusedID, equals: item.stablePresentationID)
                .disabled(cardIsDisabled(item))
        } else {
            card
        }
    }

    /// The layout width reserved for one card in the rail — its full glass-surface
    /// width, so `cardSpacing` lands as a true visible gap between cards.
    private var cardSlotWidth: CGFloat {
        switch presentation {
        case .poster:
            return metrics.posterWidth
        case .landscape:
            return metrics.cardSlotWidth(
                for: .landscape,
                cardStyle: .framed,
                showsSeriesArtwork: showsSeriesArtwork
            )
        case .episodeColumn:
            return EpisodeColumnCard.slotWidth
        }
    }

    private var layoutMetrics: PlozzMetrics {
        presentation == .episodeColumn ? .standard : metrics
    }

    private var artworkStyle: PosterCardView.Style {
        presentation == .poster ? .poster : .landscape
    }

    /// Warms the decoded-image cache in the direction the row is moving.
    ///
    /// A 181-poster Watchlist is much larger than the 96 MB decoded cache. By the
    /// far right, early posters have correctly been evicted. The old prefetcher
    /// only looked toward larger indexes and remembered every card forever, so the
    /// return trip did no work until an evicted card was already visible.
    private func prefetchArtwork(around item: MediaItem) {
        #if canImport(UIKit)
        guard let index = itemIndexByID[item.stablePresentationID] else {
            return
        }
        let lookahead = 8
        let direction = MediaRowPrefetchWindow.direction(
            from: lastArtworkPrefetchIndex,
            to: index,
            fallback: artworkPrefetchDirection
        )
        if direction != artworkPrefetchDirection {
            artworkPrefetchTasks.cancelAll()
            prefetchedIDs.removeAll(keepingCapacity: true)
            prefetchedPreviewIDs.removeAll(keepingCapacity: true)
        }
        artworkPrefetchDirection = direction
        lastArtworkPrefetchIndex = index
        let variant: ArtworkImageVariant = {
            switch presentation {
            case .poster: return .posterCard
            case .landscape, .episodeColumn: return .landscapeCard
            }
        }()
        let fullIndices = MediaRowPrefetchWindow.indices(
            from: index,
            direction: direction,
            count: items.count,
            lookahead: lookahead
        )
        for i in fullIndices {
            let candidate = items[i]
            let candidates = MediaArtworkPrefetchPolicy.candidates(
                for: candidate,
                style: artworkStyle,
                spoilerSettings: spoilerSettings,
                showsSeriesArtwork: showsSeriesArtwork
            )
            // Queue a tiny nearest-first frame before this card's heavier full
            // decode. One preview candidate is enough; if the primary is invalid,
            // the full two-candidate ladder below still handles the fallback.
            if presentation == .poster,
               let preview = candidates.first,
               ArtworkImageVariant.posterPreview.hasDistinctRequestURL(
                   from: variant,
                   for: preview
               ),
               prefetchedPreviewIDs.insert(
                   candidate.stablePresentationID
               ).inserted {
                trackPrefetch(preview, variant: .posterPreview)
            }
            if prefetchedIDs.insert(candidate.stablePresentationID).inserted {
                for url in candidates.prefix(2) {
                    trackPrefetch(url, variant: variant)
                }
            }
            // Series-artwork cards also carry a LOGO, resolved asynchronously and
            // through a different pipeline from the picture. Warming only the
            // picture meant a card scrolled onto showed its styled title first and
            // then swapped to the logo a moment later — the card visibly changing
            // under the viewer, which is the one thing a rail must not do. Warm
            // both, so the card is finished before it is reached.
            if showsSeriesArtwork {
                HeroLogoPipeline.shared.prefetch(
                    references: candidate.artworkReferences(for: .logo)
                )
                // ...and a clean, textless backdrop to draw that logo over, since
                // the server's own art often has the title baked in and would
                // print the name twice. Resolved here rather than at the card so
                // it is already decoded when the card is reached — the store
                // publishes nothing until it is, so a card can only ever see art
                // it can draw on the same frame.
                TextlessBackdropStore.shared.warm(for: candidate, variant: variant)
            }
        }
        if presentation == .poster {
            let near = Set(fullIndices)
            for i in MediaRowPrefetchWindow.indices(
                from: index,
                direction: direction,
                count: items.count,
                lookahead: 16
            ) where !near.contains(i) {
                let candidate = items[i]
                guard let preview = MediaArtworkPrefetchPolicy.candidates(
                          for: candidate,
                          style: artworkStyle,
                          spoilerSettings: spoilerSettings,
                          showsSeriesArtwork: showsSeriesArtwork
                      ).first,
                      ArtworkImageVariant.posterPreview.hasDistinctRequestURL(
                          from: .posterCard,
                          for: preview
                      ),
                      prefetchedPreviewIDs.insert(
                          candidate.stablePresentationID
                      ).inserted
                else { continue }
                trackPrefetch(preview, variant: .posterPreview)
            }
        }
        #endif
    }

    private func trackPrefetch(
        _ url: URL,
        variant: ArtworkImageVariant
    ) {
        if let task = ArtworkImageCache.shared.prefetch(
            url,
            variant: variant
        ) {
            artworkPrefetchTasks.track(task)
        }
    }

    /// Scrolls to and focuses `initialFocusID`, or — when only `initialScrollID`
    /// is set — scrolls to the target without moving focus onto it. Runs exactly
    /// once, after the row first lays out. The focus assignment is deferred a
    /// runloop tick so SwiftUI has installed the focusable cards before we move
    /// focus onto one.
    private func applyInitialFocus(using proxy: ScrollViewProxy) {
        if let target = initialFocusID,
           !didApplyInitialFocus,
           itemIDSet.contains(target) {
            didApplyInitialFocus = true
            scrollToInitialPosition(target, using: proxy)
            DispatchQueue.main.async { focusedID = target }
            return
        }
        if let target = initialScrollID,
           !didApplyInitialFocus,
           itemIDSet.contains(target) {
            didApplyInitialFocus = true
            // Defer a tick so the LazyHStack has realised enough cards to compute
            // the target's offset before we scroll; focus is deliberately left
            // wherever it currently is (typically the hero Play button).
            DispatchQueue.main.async { scrollToInitialPosition(target, using: proxy) }
        }
    }

    /// The one-shot opening scroll, which must ALWAYS align the target to the
    /// leading edge — unlike `scrollToIfNeeded`, which skips the work when the
    /// target is already on screen.
    ///
    /// That skip is right for re-entry (it's what stops the row snapping while you
    /// browse) but wrong here. `visibleIDs` is fed by the LazyHStack's `onAppear`,
    /// which fires for a buffer of cards beyond the viewport, so an early episode
    /// counts as "visible" while still sitting mid-row. The opening scroll was
    /// therefore skipped and the row opened un-aligned; the episode only snapped
    /// into first position later, when focus left the row and the re-entry scroll
    /// finally ran with the target genuinely off screen. That's the "teleport".
    private func scrollToInitialPosition(_ target: String, using proxy: ScrollViewProxy) {
        proxy.scrollTo(target, anchor: .leading)
    }

    /// Responds to focus moving onto a card (`newValue` non-nil) or off the row
    /// (`nil`). When focus *enters* the row and a gate target is set, the first
    /// card tvOS picks (the geometrically-nearest one) is overridden by moving
    /// focus to the target — the episode you came in on, or the one you last
    /// looked at — so down-from-the season tabs always lands on the right episode
    /// regardless of geometry. Once engaged, normal left/right browsing is
    /// untouched; leaving the row (debounced) re-arms entry targeting on the card
    /// you were last on.
    private func handleFocusChange(to newValue: String?, using proxy: ScrollViewProxy) {
        // A fast horizontal hold constantly blips focus to `nil` between cards (the
        // focused card is recycled out of the lazy stack for a frame). Ignore it
        // entirely: re-arming here is what used to disable every card mid-scroll and
        // strand the focus indicator. The gate now re-arms only on `focusResetToken`
        // (focus actually left the row, up to the season bar).
        guard let newValue else { return }
        hasBrowsedSinceTargetChange = true
        if !focusEngaged { onFocusEntered?() }
        lastFocusedID = newValue
        if !focusEngaged,
           let target = gateTarget,
           newValue != target,
           itemIDSet.contains(target) {
            // Safety net: if focus somehow lands on a non-target card while gated
            // (e.g. a frame before `.disabled` applied), redirect to the target and
            // don't report the transient card to the hero.
            focusEngaged = true
            lastFocusedID = target
            redirectFocus(to: target, using: proxy)
            return
        }
        focusEngaged = true
        scheduleFocusReport(for: newValue)
    }

    /// Restores focus to the card the row was on before its page was covered.
    ///
    /// Claimed immediately so the target is focused in the same frame the page
    /// reappears — deferring it entirely let the system's own restoration land
    /// visibly first (on the cast row, or the wrong card) before jumping. It is
    /// then re-asserted once, because that restoration can still arrive after
    /// ours and overwrite it.
    private func reclaimFocusAfterCovering(using proxy: ScrollViewProxy) {
        guard let target = coveredFocusID, itemIDSet.contains(target) else {
            coveredFocusID = nil
            onRefocusComplete?()
            return
        }
        scrollToIfNeeded(target, using: proxy)
        claimFocus(target)
        // Hold the other cards non-focusable across the system's own restoration
        // (`coveredFocusID` still set), then release them. Re-asserting after it
        // has already moved focus is what produced the visible jump.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            claimFocus(target)
            coveredFocusID = nil
            onRefocusComplete?()
        }
    }

    private func claimFocus(_ target: String) {
        guard focusedID != target else { return }
        focusedID = target
        lastFocusedID = target
        focusEngaged = true
    }

    /// Coalesces hero updates: each focus change schedules a deferred report and
    /// cancels the previous one, so blasting RIGHT through a long season rebuilds
    /// the hero once — when focus settles — instead of once per card passed.
    private func scheduleFocusReport(for id: String) {
        let item = itemByID[id]
        pendingReport?.cancel()
        let work = DispatchWorkItem {
            // Only report the card focus actually settled on, skipping every card
            // blown past during a rapid hold.
            guard focusedID == id else { return }
            prefetchHeroPreview(for: item)
            onFocusChange?(item)
        }
        pendingReport = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    /// Warms the focused card's DETAIL BACKDROP at preview size, so opening it
    /// paints a real image on the first frame instead of a scrim.
    ///
    /// The forward-window prefetch above warms each card's own artwork — a poster,
    /// at poster size. A detail page's hero wants a different image entirely, so
    /// none of that helps it and every open started cold.
    ///
    /// Three things keep this from becoming the kind of unbounded work that
    /// overheats the device: it runs only for the card focus SETTLES on (the same
    /// 0.08s coalescing the hero report uses, so holding RIGHT through a row warms
    /// one image rather than fifty), only at `.heroPreview` — 768px, a fraction of
    /// the 2000px the page eventually shows — and only once per card. The cache
    /// itself also skips anything already resident or in flight, and decodes off
    /// the main thread.
    ///
    /// Deliberately no TMDb fallback here: that is a network round trip to decide
    /// what to fetch, which is far too much to spend on a card the viewer may
    /// simply be scrolling past. A title with no local backdrop keeps the
    /// progressive load it already had.
    ///
    /// Only the FIRST reference is warmed, while the hero picks the first that is
    /// also ≤ 3:1 once loaded. A server backdrop is 16:9, so these agree in
    /// practice; when they don't, the hero simply loads as it did before — a miss
    /// costs nothing, where warming every candidate would cost on every card.
    private func prefetchHeroPreview(for item: MediaItem?) {
        #if canImport(UIKit)
        guard let item,
              !prefetchedHeroIDs.contains(item.stablePresentationID) else {
            return
        }
        let references = item.artworkReferences(for: .detailBackdrop)
        guard let reference = references.first else { return }
        prefetchedHeroIDs.insert(item.stablePresentationID)
        ArtworkImageCache.shared.prefetch(reference, variant: .heroPreview)
        #endif
    }

    /// Scrolls the target card into view (realising it in the lazy stack if needed)
    /// then moves focus onto it a runloop tick later, once it exists.
    private func redirectFocus(to target: String, using proxy: ScrollViewProxy) {
        scrollToIfNeeded(target, using: proxy, animated: true)
        DispatchQueue.main.async { focusedID = target }
    }

    /// Avoids unnecessary `scrollTo` calls when the target is already realised and
    /// visible in the row, eliminating jumpy re-entry and extra layout churn.
    private func scrollToIfNeeded(
        _ target: String,
        using proxy: ScrollViewProxy,
        anchor: UnitPoint = .leading,
        animated: Bool = false
    ) {
        guard !visibleIDs.contains(target) else { return }
        if animated {
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(target, anchor: anchor)
            }
        } else {
            proxy.scrollTo(target, anchor: anchor)
        }
    }
}

enum MediaRowPrefetchWindow {
    static func direction(
        from previousIndex: Int?,
        to index: Int,
        fallback: Int
    ) -> Int {
        guard let previousIndex, previousIndex != index else {
            return fallback < 0 ? -1 : 1
        }
        return index < previousIndex ? -1 : 1
    }

    static func indices(
        from index: Int,
        direction: Int,
        count: Int,
        lookahead: Int
    ) -> [Int] {
        guard count > 0, index >= 0, index < count else { return [] }
        if direction < 0 {
            let lower = max(0, index - max(lookahead, 0))
            return Array(stride(from: index, through: lower, by: -1))
        }
        let upper = min(count - 1, index + max(lookahead, 0))
        return Array(index...upper)
    }
}

private final class ArtworkPrefetchTasks {
    private var tasks: [Task<Void, Never>] = []

    func track(_ task: Task<Void, Never>) {
        tasks.append(task)
    }

    func cancelAll() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll(keepingCapacity: true)
    }

    deinit {
        tasks.forEach { $0.cancel() }
    }
}

enum MediaRowFocusPolicy {
    static func observesFocus(
        initialFocusID: String?,
        defaultFocusID: String?,
        hasOnFocusEntered: Bool,
        hasOnFocusChange: Bool
    ) -> Bool {
        initialFocusID != nil
            || defaultFocusID != nil
            || hasOnFocusEntered
            || hasOnFocusChange
    }

    static func usesEntryGate(defaultFocusID: String?) -> Bool {
        defaultFocusID != nil
    }
}

public enum MediaArtworkPrefetchPolicy {
    public static func candidates(
        for item: MediaItem,
        style: PosterCardView.Style,
        spoilerSettings: SpoilerSettings,
        showsSeriesArtwork: Bool = false
    ) -> [URL] {
        // Series-artwork mode paints show art on every card regardless of watch
        // state, so warm that rather than a thumbnail the card will never draw.
        // Movies and series keep their own art — they already *are* the show.
        if showsSeriesArtwork {
            guard item.kind == .episode else { return item.artworkCandidates(for: style) }
            return seriesArtworkCandidates(for: item, style: style)
        }
        if item.kind == .episode,
           spoilerSettings.shouldHideThumbnail(for: item),
           spoilerSettings.mode == .placeholder || style == .poster {
            // Mirrors `PosterCardView`'s two spoiler-safe paths: `.placeholder`
            // mode on any shape, and every poster-shaped episode card regardless
            // of mode (see `showsSpoilerSafePoster` — those draw series art sharp
            // rather than blurring it). Series-level art only, ordered for the
            // card's shape. Kept in step with that ladder so the image warmed here
            // is the one the card actually paints — warming only
            // `fallbackArtworkURL` meant Plex and direct-share cards prefetched
            // nothing at all, since neither ever set it.
            //
            // The `.episode` test is redundant today (`shouldHideThumbnail` only
            // ever answers true for an episode) and is here anyway, because the
            // view's `showsSpoilerSafePoster` checks it independently. Without it
            // the two sides are only correct by coupling: widen the spoiler rule
            // to another kind — as `shouldHideRatings` was widened to series and
            // seasons — and this would warm series art for a movie whose own
            // poster the card is still drawing.
            return seriesArtworkCandidates(for: item, style: style)
        }
        return item.artworkCandidates(for: style)
    }

    /// Spoiler-safe show art for an episode, ordered for the card's shape: a wide
    /// card wants the show's backdrop, a poster card its vertical poster, each
    /// keeping the other as a last resort.
    private static func seriesArtworkCandidates(
        for item: MediaItem,
        style: PosterCardView.Style
    ) -> [URL] {
        let candidates = style == .poster
            ? [item.seriesPosterURL, item.fallbackArtworkURL]
            : [item.fallbackArtworkURL, item.seriesPosterURL]
        return candidates.compactMap { $0 }
    }
}

private extension View {
    /// Applies `.focusSection()` only when `enabled`. Used so the gated episode
    /// rail keeps its single-section entry behavior while ordinary rows stay plain
    /// focusable scrollers whose vertical navigation is column-aligned by tvOS's
    /// geometric X-projection (no per-section last-focus memory).
    @ViewBuilder
    func focusSectionIf(_ enabled: Bool) -> some View {
        #if os(tvOS)
        if enabled {
            focusSection()
        } else {
            self
        }
        #else
        self
        #endif
    }
}

#endif
