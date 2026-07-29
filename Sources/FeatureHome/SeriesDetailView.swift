#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreNetworking
import CoreUI
import FeatureHomeCore
import MetadataKit

/// A single, self-contained page for an entire series. The hero at the top
/// describes whatever the Play button would play — the episode to resume, or the
/// show itself when there is no resume point. It follows watch state, never
/// focus, so browsing the episode rail leaves it alone and both platforms behave
/// identically (iPadOS has no focus concept at all).
///
/// Layout, top to bottom:
///   1. Hero — series by default; becomes the focused season, then the focused
///      episode, as focus moves down the page.
///   2. Season tabs ("Book One: Water", …). Focusing a tab previews that season
///      in the hero and swaps the episode rail to it; no click required.
///   3. Episode rail for the selected season. Focusing an episode previews it in
///      the hero; clicking it plays it (the parent applies resume-vs-start-over).
struct SeriesDetailView: View {
    let series: MediaItem
    let seasons: [MediaItem]
    /// Episodes attached directly to the series (used when a backend returns a
    /// flat episode list with no season containers).
    let looseEpisodes: [MediaItem]
    /// `looseEpisodes` stamped once with `SeriesTmdb` so focus-driven hero updates
    /// don't repeatedly remap huge episode arrays in `body`.
    private let stampedLooseEpisodes: [MediaItem]
    let viewModel: ItemDetailViewModel
    let spoilerSettings: SpoilerSettings
    let onPlay: (MediaItem) -> Void
    let requestAvailability: MediaRequestAvailability?
    let isRequestingSeasons: Bool
    let onRequestSeasons: (([Int]) -> Void)?
    /// Switches this page to another server's copy of the show when the user picks
    /// a different server in the hero's "…" menu. The switch happens IN PLACE
    /// (the view model re-points to the other server and reloads its seasons/
    /// episodes) so it does not grow the navigation back stack — pressing Back
    /// still returns to wherever the user opened the show from. `nil` (e.g.
    /// previews, or a single-server show) hides the server picker.
    let onSelectServer: ((MediaSourceRef) -> Void)?
    /// Opens another title from the Related row.
    let onSelectRelated: (MediaItem) -> Void
    /// When the page was opened targeting a specific season, that season's id.
    let initialSeasonID: String?
    /// When the page was opened by tapping a specific episode, that episode. The
    /// page selects its season and opens focus on the matching active-server card.
    /// Hero Play remains the true resume/next-up target.
    let initialEpisode: MediaItem?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Which season's episodes the rail is currently showing. Driven by season
    /// tab focus; seeded to the "next up" season on first appearance.
    @State private var selectedSeasonID: String?
    /// The item the hero is currently presenting. Updated as focus moves; it is
    /// never cleared, so moving focus onto a non-previewing control (e.g. the
    /// hero's own Play button) keeps the last meaningful context.
    @State private var heroItem: MediaItem
    @FocusState private var focusedSeasonID: String?
    @FocusState private var requestSeasonsFocused: Bool
    /// True once focus is *inside* the season bar. While false, only the active
    /// season chip is focusable, so entering the bar (from Play above or the
    /// episodes below) lands directly on the active season with no visible
    /// snap from a geometrically-nearer chip. Once true, every chip is focusable
    /// so left/right moves freely between seasons; it resets when focus leaves.
    @State private var seasonBarEngaged = false
    /// Bumped whenever focus enters the season tab bar. Handed to the episode rail
    /// as its `focusResetToken` so the rail re-arms its entry gate deterministically
    /// when focus has truly left it (gone up to the bar) — rather than inferring it
    /// from a transient `nil` during a fast horizontal hold, which could strand the
    /// focus indicator.
    @State private var episodeRailResetToken = 0
    /// Latched once the page has opened, so `defaultFocus` claims Play exactly
    /// once. It is declarative and re-evaluates on every appearance — including a
    /// pop — where it would override the returning user's focus.
    @State private var hasOpenedOnce = false
    /// Latched once the opening claim on Play has been settled.
    ///
    /// `defaultFocus` fires when the page appears, but the hero's Play button only
    /// EXISTS once `playTarget` resolves — and on a season page that's an async
    /// load. Open before it lands and the action row's first focusable is whatever
    /// else is there (the watched button), so tvOS gives entry focus to "Mark as
    /// Watched" and the already-spent `defaultFocus` never reclaims it. Re-asserting
    /// Play the moment it appears is what makes the page open on Play reliably.
    @State private var hasSettledOpeningFocus = false
    /// Set as soon as the user genuinely drives focus somewhere themselves (into
    /// the rail or the season bar). It fences the re-assert above so a fast user
    /// who has already moved on is never yanked back up to Play.
    @State private var hasUserDirectedFocus = false
    /// True from the moment a pushed page pops until the rail has reclaimed
    /// focus. `hasChildOnTop` alone is too short a window: it clears the instant
    /// the pop completes, and tvOS then parks focus on the hero — restoring it
    /// and hiding the cast — before the rail takes focus back.
    @State private var isReclaimingFocus = false
    /// Suppresses the duplicate Play/row focus callback emitted when focus first
    /// returns from the browser to the real hero controls.
    @State private var suppressesDuplicateHeroFocus = false

    /// Drives initial focus onto Hero Play for whole-show/season opens. Individual
    /// episode opens assign initial focus through the episode rail instead.
    @FocusState private var playFocused: Bool
    /// The user's in-session quality choice for the current play-target episode,
    /// chosen from the hero "…" menu's Version section. Cleared implicitly when it
    /// no longer matches the target episode's versions (a different episode's files
    /// have different ids), so `effectivePlayVersionID` re-defaults to recommended.
    @State private var versionOverride: String?

    /// The measured width of the season tab bar's scroll viewport (its own width,
    /// before the external leading inset), i.e. the right edge of the visible region
    /// in `seasonBarSpace`. Used together with the per-chip frames below to decide
    /// whether the active chip is already fully on-screen (skip the auto-scroll) and,
    /// when it isn't, which edge it is clipped past. `0` until first layout.
    @State private var seasonBarViewportWidth: CGFloat = 0

    /// Live frame of the pending reveal target in the bar's own coordinate space
    /// (`seasonBarSpace`). Lets us tell whether the active chip is already fully
    /// visible — so we DON'T shift an already-on-screen bar — and, when it isn't,
    /// which edge it is clipped past so we reveal it minimally to that edge instead
    /// of yanking it to the leading keyline. Measurement exists only while the
    /// one-shot reveal is pending; normal horizontal scrolling publishes no frames.
    @State private var seasonChipFrames: [String: CGRect] = [:]

    /// One-shot arm for the active-season reveal. Set when the bar appears or the
    /// selection changes externally; consumed once the chip frames are measured, so
    /// the reveal only ever runs with real geometry (never a premature leading-align)
    /// and never loops on its own animated scroll.
    @State private var pendingSeasonReveal = false

    /// The season+episode NUMBER to re-front after an IN-PLACE cross-server switch,
    /// captured from the currently-fronted episode the instant the user picks a new
    /// server. Once that server's episodes load, the page re-selects the matching
    /// season and fronts the same S·E episode (per-server ids differ, so we match
    /// by number) — keeping the user on the same episode across the switch. `nil`
    /// when no episode was fronted or after it has been consumed.
    @State private var pendingSwitchTargetSE: SeasonEpisodeRef?

    /// The episode the rail should land on when focus enters it (its
    /// `defaultFocusID`): the came-in/tapped episode on open, the preserved episode
    /// after a cross-server switch, or the selected season's next-up. It is updated
    /// ONLY at those discrete moments — never from the live `heroItem` as the user
    /// browses cards. Deriving the rail's default focus from `heroItem`/`playTarget`
    /// (which change on every card focus) re-armed `MediaRowView`'s entry gate on
    /// each card and made scrolling the rail snap back; a stable target keeps it
    /// silky smooth while still re-pointing on open/season-change/switch.
    @State private var railTargetID: String?
    /// Full per-item media facts for the resting Play target. Kept outside the
    /// episode rail so badge enrichment never rewrites hundreds of visible cards.
    @State private var restingPlayTargetEnrichment: MediaItem?
    /// Cosmetic-only series hero recede state. The parent writes it but never reads
    /// it, so episode focus changes do not invalidate this page or its rail.
    @State private var recedeModel = SeriesHeroRecedeModel()
    /// Whether another detail page is pushed on top of this one — see
    /// `DetailStackDepth`. Supplied by the hosting page, which owns the counter
    /// and so is the only view that can record its own level correctly.
    private let hasChildOnTop: Bool

    init(
        series: MediaItem,
        hasChildOnTop: Bool = false,
        seasons: [MediaItem],
        looseEpisodes: [MediaItem],
        viewModel: ItemDetailViewModel,
        spoilerSettings: SpoilerSettings,
        onPlay: @escaping (MediaItem) -> Void,
        requestAvailability: MediaRequestAvailability? = nil,
        isRequestingSeasons: Bool = false,
        onRequestSeasons: (([Int]) -> Void)? = nil,
        onSelectServer: ((MediaSourceRef) -> Void)? = nil,
        onSelectRelated: @escaping (MediaItem) -> Void = { _ in },
        initialSeasonID: String? = nil,
        initialEpisode: MediaItem? = nil
    ) {
        self.series = series
        self.hasChildOnTop = hasChildOnTop
        self.seasons = seasons
        self.looseEpisodes = looseEpisodes
        self.stampedLooseEpisodes = SeriesEpisodeContext(series: series).stamping(looseEpisodes)
        self.viewModel = viewModel
        self.spoilerSettings = spoilerSettings
        self.onPlay = onPlay
        self.requestAvailability = requestAvailability
        self.isRequestingSeasons = isRequestingSeasons
        self.onRequestSeasons = onRequestSeasons
        self.onSelectServer = onSelectServer
        self.onSelectRelated = onSelectRelated
        self.initialSeasonID = initialSeasonID
        self.initialEpisode = initialEpisode
        // When opened via "Go to Season", pre-select that season (and front it in
        // the hero) so the page lands on the requested season rather than the
        // default one. When opened by tapping an episode, front that episode and
        // select its season instead.
        let seasonID = initialEpisode?.seasonID ?? initialSeasonID
        let initialSeason = seasonID.flatMap { id in seasons.first { $0.id == id } }
        _selectedSeasonID = State(initialValue: initialSeason?.id)
        _heroItem = State(initialValue: initialSeason ?? series)
        _railTargetID = State(initialValue: initialEpisode?.id)
    }

    /// Scroll anchor for the hero, used to keep the page pinned to the top while
    /// initial focus lands on the bottom-anchored Play button.
    private static let topAnchorID = "series-hero-top"
    /// The episode column's visual-center marker, used identically when focus first
    /// enters either Seasons or Episodes.
    private static let browserFocusAnchorID = "series-episode-browser-focus"
    /// Scroll target for the cast/Related block — the browser's deliberate
    /// downward exit, which we animate ourselves because the page is frozen while
    /// focus is inside the browser.
    private static let extrasAnchorID = "series-extras-top"
    /// One duration for the entire hero↔browser transition, matching Home. Every
    /// moving part inherits this ambient transaction instead of carrying its own
    /// `.animation`, so the return scroll and the hero/backdrop transforms can
    /// never run at different speeds.
    private static let recedeAnimationDuration: CGFloat = 0.9

    /// Named coordinate space anchored to the season bar's scroll viewport. In it the
    /// visible region is exactly `0...seasonBarViewportWidth`, so each chip's frame
    /// (published into `seasonChipFrames`) reflects the live scroll offset — letting
    /// us decide true visibility and the clipped edge for a minimal reveal.
    private static let seasonBarSpace = "seasonBarViewport"


    var body: some View {
        let _ = plozzPrintChanges { Self._printChanges() }
        scrollContent
            // Never clip a focused card's lift, shadow or border.
            .scrollClipDisabled()
            // Let the hero bleed into the top overscan inset instead of the
            // ScrollView reserving it as a blank bar above the backdrop.
            .ignoresSafeArea(.container, edges: .top)
            // Re-run when the season set changes — not just once on first appear.
            // A seeded page first renders with empty `seasons` (children haven't
            // loaded yet); keying on the season ids re-runs this the moment they
            // arrive so a series/episode entry (selectedSeasonID still nil) picks
            // its first season and loads episodes instead of staying empty.
            .task(id: seasonSetKey) { await prepareInitialSeason() }
            // Keep the series-level hero in sync with the active server: when an
            // in-place cross-server switch re-points `series` to the other server's
            // copy while the hero is showing the show itself (no episode fronted),
            // adopt the new series so the hero's title/overview match the active
            // server. Skipped while an episode is fronted (the episode drives the
            // hero, and `frontSwitchTarget` re-fronts the matching one).
            .onChange(of: series.id) { _, _ in
                if heroItem.kind == .series { heroItem = series }
            }
            // Warm the current season's episode thumbnails as soon as they load, so
            // cards already have their thumbnail when scrolled to rather than
            // visibly fetching it on appear.
            .task(id: stillPrefetchKey) { await prefetchSeasonStills() }
            // Background-warm nearby seasons so switching later is instant. A
            // single-season series has no neighbors, so this is a no-op there.
            .task(id: seasonSetKey) { await prewarmAllSeasons() }
            // The hero holds a local copy of its item, so when a watched/watchlist
            // mutation broadcasts (e.g. from the hero's own Watched button), flip
            // the same flags on `heroItem` in place so the visible hero button
            // reflects the new state immediately.
            //
            // Marking the fronted episode watched then makes the hero *stale*: it
            // now describes something finished while Play still points at it. The
            // resting hero is derived from watch state, so re-derive it — the page
            // moves on to the next episode the way it would on a fresh open. A
            // The tapped episode is browser context only, so every entry route
            // advances the resting hero when its Play target becomes watched.
            .onReceive(NotificationCenter.default.publisher(for: .mediaItemDidMutate)) { note in
                guard let mutation = MediaItemMutation.from(note) else { return }
                if mutation.targets(heroItem) {
                    heroItem = mutation.applied(to: heroItem)
                } else if heroItem.kind == .episode,
                          mutation.targets(series),
                          let played = mutation.played {
                    heroItem.isPlayed = played
                }
                guard heroItem.kind == .episode, heroItem.isPlayed else {
                    return
                }
                Task { await resolveRestingHero(in: selectedSeasonID) }
            }
    }

    @ViewBuilder
    private var scrollContent: some View {
        // Whole-show/season entry lands on Hero Play. Individual episode entry
        // lands on its rail card through MediaRowView's initial focus.
        //
        // Only on a genuine open. `defaultFocus` is declarative and re-fires on
        // every appearance, so on a pop back from a pushed page it yanked focus
        // off whatever the user was on — and because Play taking focus restores
        // the hero, that also collapsed the episode browser and hid the cast.
        // Designating `false` leaves no target (nothing binds `equals: false`),
        // which keeps the modifier applied unconditionally so view identity is
        // stable, rather than branching it in or out of the hierarchy.
        scroll
            .defaultFocus(
                $playFocused,
                SeriesDetailEntryPolicy.claimsHeroPlay(
                    hasOpenedOnce: hasOpenedOnce,
                    hasInitialEpisode: initialEpisode != nil
                )
            )
            .onAppear { hasOpenedOnce = true }
            // The Play button appears only once the play target resolves; until
            // then there is nothing for `defaultFocus` to land on. Claim it the
            // moment it exists — but only during the opening window, and never
            // once the user has driven focus themselves.
            .onChange(of: playTarget?.id) { _, resolved in
                guard resolved != nil,
                      initialEpisode == nil,
                      !hasSettledOpeningFocus,
                      !hasUserDirectedFocus,
                      !hasChildOnTop
                else { return }
                hasSettledOpeningFocus = true
                playFocused = true
            }
            .onChange(of: hasChildOnTop) { _, covered in
                // Returning from a pushed page. tvOS hands focus to the hero
                // rather than back to the rail (verified on device: the rail
                // receives no focus event at all), so the rail has to reclaim it
                // for the episode the user actually left from — which it still
                // remembers correctly.
                guard !covered else { return }
                isReclaimingFocus = true
            }


    }

    /// Whether this open lands focus inside the browser rather than on Hero Play
    /// (i.e. the user tapped a specific episode). Such an open must start receded
    /// so the targeted rail card is already on screen.
    ///
    /// Deliberately NOT `!SeriesDetailEntryPolicy.claimsHeroPlay(…)`: that also
    /// consults `hasOpenedOnce`, a latch `.onAppear` sets *before* the opening
    /// `.task` runs. Reading it here therefore always saw `true` and receded
    /// every open, hero and all. `hasOpenedOnce` exists only to stop
    /// `defaultFocus` re-claiming Play on a re-appear; the entry arrangement
    /// depends purely on whether a specific episode was tapped.
    private var entersBrowserOnOpen: Bool {
        initialEpisode != nil
    }

    /// Whether focus changes arriving now are the system's rather than the
    /// user's — while a child page is on top, or while the rail is reclaiming
    /// focus just after one pops.
    private var ignoresSystemFocusMoves: Bool {
        hasChildOnTop || isReclaimingFocus
    }

    private var scroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    DetailHeroView(
                        item: displayHeroItem,
                        backdropItem: series,
                        titleFallbackOverride: series.title,
                        // Watched-state actions follow what Play would run. When
                        // the hero rests on the show, marking watched must not
                        // sweep the entire series.
                        actionItem: playTarget,
                        seriesRecedeModel: recedeModel,
                        scheduleLine: upcomingHeroLine,
                        spoilerSettings: spoilerSettings,
                        playTitle: playTarget.map { viewModel.playButtonTitle(for: $0) },
                        onPlay: playTarget.map { target in { onPlay(target.selectingVersion(effectivePlayVersionID)) } },
                        playProgress: playTarget?.resumeProgressFraction,
                        playRemainingText: playTarget?.resumeRemainingText,
                        playSeasonEpisodeText: playTarget.flatMap { HeroForegroundModelBuilder.seasonEpisodeButtonText(for: $0) },
                        onPlayTrailer: trailerButtonAction,
                        versions: playVersions,
                        selectedVersionID: effectivePlayVersionID,
                        onSelectVersion: playVersions.count > 1 ? { versionOverride = $0 } : nil,
                        sources: distinctServerChoices,
                        offlineSourceAccountIDs: viewModel.unreachableSourceAccountIDs,
                        selectedSourceAccountID: series.sourceAccountID,
                        onSelectSource: serverPickerAction,
                        fallbackTechnicalBadges: playTargetTechnicalBadges,
                        playButtonFocus: $playFocused,
                        // Keep the whole hero action row pinned to the top for every
                        // button, not just Play — moving right to Trailer / the "…"
                        // menu / Refresh otherwise lets tvOS's focus-reveal auto-
                        // scroll drift the page down. Same animation as the
                        // Play-regains-focus case below.
                        onHeroActionFocused: {
                            // The second path by which the system's focus moves
                            // reach the hero. Guarded identically: while a child
                            // page is on top this is tvOS re-establishing focus
                            // by geometry, not the user pressing up.
                            guard !ignoresSystemFocusMoves else { return }
                            handleHeroFocus(using: proxy)
                        }
                    )
                    .id(Self.topAnchorID)
                    // Episodes are seeded from the season's `/children` listing,
                    // which on Plex can omit the per-stream DoVi/HDR facts and the
                    // Media-level Atmos hint. Enrich whichever episode the hero is
                    // showing from a full per-item fetch so its badges are accurate
                    // (cached per id; cancels automatically as focus moves on).
                    .task(id: heroItem.id) {
                        guard heroItem.kind == .episode else { return }
                        if let enriched = await viewModel.enrichEpisodeBadgesIfNeeded(heroItem),
                           enriched.id == heroItem.id {
                            heroItem = enriched
                        }
                    }
                    // Proactively enrich the episode Play will run. Browser entry
                    // may target a different tapped episode, so keying this work to
                    // the rail would show that card's file badges above a resume
                    // button that starts another episode.
                    .task(id: playTarget?.id) {
                        guard let target = playTarget else { return }
                        let id = target.id
                        let enriched = await viewModel.enrichEpisodeBadgesIfNeeded(target)
                        guard playTarget?.id == id else { return }
                        restingPlayTargetEnrichment = enriched
                    }

                    SeriesEpisodeBrowser(
                        series: series,
                        recedeModel: recedeModel,
                        showsSeasons: !seasons.isEmpty || requestAvailability?.hasSeasonRequestContent == true,
                        focusAnchorID: Self.browserFocusAnchorID,
                        seasonContent: {
                            // Keep the season chips + "request seasons" button hidden
                            // while focus is up in the hero; reveal them once the page
                            // scrolls down into the browser. The bar stays in the
                            // hierarchy (opacity, not removed) so pressing down still
                            // lands on the active season chip.
                            //
                            // `seasonBarEngaged` is an additional reveal condition
                            // because the recede is now a function of scroll offset:
                            // if the focus engine ever moves onto the bar without
                            // scrolling past the threshold, the chips must still be
                            // visible rather than leaving focus on invisible controls.
                            SeriesRecedeReveal(
                                recedeModel: recedeModel,
                                forceVisible: seasonBarEngaged
                            ) {
                                seasonTabBar { revealBrowser(using: proxy) }
                            }
                        },
                        episodeContent: {
                            episodeRail { revealBrowser(using: proxy) }
                        }
                    )
                    // Static. The browser's layout position never changes — it is
                    // permanently at its browsing position, which is what keeps
                    // the season bar and episode rail inside the viewport and the
                    // focus engine quiet. The resting look comes from the
                    // browser's own render-only `.offset`, and the sections below
                    // therefore never move either.
                    .padding(.top, -SeriesEpisodeBrowserLayout.heroOverlap)

                    DetailExtrasView(
                        item: series,
                        selectedSource: distinctServerChoices.first { $0.accountID == series.sourceAccountID }
                            ?? viewModel.currentSourceForDisplay,
                        selectedVersion: playVersions.first { $0.id == effectivePlayVersionID }
                            ?? playVersions.first
                            ?? playTarget.map { MediaVersion.synthesized(from: $0) },
                        leadingInset: PlozzTheme.Metrics.heroLeadingPadding,
                        seriesRecedeModel: recedeModel,
                        revealsSeriesCastWithoutBrowser: revealsCastWithoutBrowser,
                        suppressesFocus: ignoresSystemFocusMoves,
                        onCastFocusEntered: { seasonBarEngaged = false },
                        relatedEntries: viewModel.relatedTitlesLoader?.entries ?? [],
                        relatedHasResolved: viewModel.relatedTitlesLoader?.hasResolved ?? true,
                        onSelectRelated: onSelectRelated
                    )
                        .padding(.top, 32)
                        .plzGeoLog("extras")
                        .id(Self.extrasAnchorID)
                }
                .padding(.bottom, PlozzTheme.Metrics.screenVerticalPadding)
                // Cap the whole scroll column to the proposed (safe viewport)
                // width. The hero backdrop still bleeds edge-to-edge via its own
                // `.ignoresSafeArea`, but its layout footprint — and any over-wide
                // row below (e.g. a long tags strip) — can no longer inflate the
                // column past the viewport, which is what let tvOS pan the page
                // sideways and shove focus off the left edge.
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Keep the page pinned to the top on first load. The Play button is
            // bottom-anchored in the full-screen hero, so when initial focus
            // lands on it tvOS auto-scrolls to frame it "comfortably", nudging
            // the backdrop top off screen. Snap back to the hero top so focus
            // stays on Play without the page appearing scrolled down; moving
            // down to the seasons scrolls normally from there.
            // Snap back to the hero top whenever Play regains focus (e.g. moving
            // "up" from the seasons), animated so the page glides up smoothly
            // rather than jumping instantly.
            .onChange(of: playFocused) { _, focused in
                // tvOS re-establishes focus by geometry whenever the stack
                // changes, landing on the topmost control — Play. While a child
                // page is on top that is the system moving focus, not the user
                // pressing up out of the browser, and acting on it collapsed the
                // browser (hiding the cast) as the child was pushed.
                guard !ignoresSystemFocusMoves else { return }
                if focused {
                    handleHeroFocus(using: proxy)
                }
            }
            // THE recede driver — byte-for-byte Home's mechanism, and the reason
            // the "hybrid" state is now structurally impossible.
            //
            // Every earlier attempt drove the recede off FOCUS events ("focus
            // entered the browser → recede"). Focus and scroll offset are two
            // independent quantities on tvOS, so they could disagree: pressing UP
            // quickly out of the episode rail lands focus on the season bar, but
            // the focus engine's own reveal scrolls the page much further than
            // that (it anticipates the move toward the top), dragging the hero
            // back into view while `isReceded` was still true. Result: full hero
            // artwork sharing the screen with a receded layout.
            //
            // Reading the recede FROM the scroll offset makes the two quantities
            // one quantity. However far tvOS decides to scroll — slow, fast, or
            // overshooting — the hero's state is a pure function of where the page
            // actually is, so the visuals can never contradict the geometry. We
            // never fight the focus engine; we follow it.
            //
            // Note this only flips on the threshold CROSSING, not per scroll
            // frame, so it costs one state write per transition rather than
            // invalidating the page dozens of times a second.
            // The page must NOT drive the recede any more.
            //
            // Reading it from `contentOffset` was correct while the browser
            // depended on the page scrolling to bring the episode rail on screen.
            // Now the receded stage is fully visible at offset 0, so the page
            // legitimately never moves during the hero↔browser transition and a
            // scroll-derived flag would be stuck at `false` forever. The recede is
            // driven by focus entering the browser instead — which is safe here
            // precisely *because* no scroll happens: the two quantities that used
            // to disagree can no longer both change.
            .onChange(of: entersBrowserOnOpen) { _, entersBrowser in
                // Opening straight onto an episode focuses a rail card before the
                // user does anything. Recede immediately so that card is already
                // on screen and the engine has nothing to reveal.
                guard entersBrowser else { return }
                recedeModel.isReceded = true
            }
            // Freeze the PAGE while focus lives inside the browser.
            //
            // This is the rule that makes the transition deterministic: moving
            // between Seasons and Episodes must never move the page. tvOS's focus
            // engine otherwise runs its own reveal scroll on every such move, and
            // that reveal deliberately overshoots to "anticipate" where focus is
            // heading — pressing UP from a card to the season bar would sail the
            // page all the way back toward the hero even though focus stopped at
            // Season 1. No amount of animation tuning could fix that, because the
            // page was being moved by something we didn't control.
            //
            // `scrollDisabled` turns off the underlying scroll view's
            // focus-driven scrolling, so within the browser the page simply
            // cannot move. Programmatic `scrollTo` still works, which is how the
            // two deliberate exits (up to the hero, down to the cast) own their
            // own animated transitions.
            .task {
                try? await Task.sleep(nanoseconds: 50_000_000)
                proxy.scrollTo(Self.topAnchorID, anchor: .top)
                if entersBrowserOnOpen {
                    recedeModel.isReceded = true
                }
            }
        }
    }

    /// Focus returning to a hero button scrolls the page back to the top, exactly
    /// like Home's `onFocusGained`.
    ///
    /// The recede is cleared HERE, inside the same `withAnimation` as the scroll,
    /// so the hero content travels back down **in parallel with** the return
    /// scroll. Leaving it to the scroll observer alone means the un-recede can't
    /// even start until the page has already scrolled back under the threshold —
    /// which stacks scroll-time + un-recede-time and reads as the page catching
    /// and then animating the hero down as a second, separate motion. The
    /// observer still runs as a backstop for every other way the page can move
    /// (notably the focus engine's own reveal scrolls), which is what keeps the
    /// state and the geometry from ever disagreeing.
    ///
    /// The explicit scroll is needed because the focus engine won't do it for us:
    /// the hero buttons stay focusable (never hidden) while transformed
    /// off-screen, so from the engine's point of view they are already "revealed"
    /// and it sees no reason to move the page.
    /// Focus has entered the season bar or the episode rail. Every moving part —
    /// browser drop, hero content lift, backdrop parallax, logo fade — is a
    /// render-only transform, so the state change is the whole visual transition.
    ///
    /// The `scrollTo` covers the one case where the page legitimately *is*
    /// scrolled: arriving from Cast/Related below. Those rows live past the fold,
    /// so focus down there leaves the page some hundreds of points down, and
    /// tvOS's reveal on the way back up only scrolls the minimum needed — parking
    /// the episode rail against the top edge with the hero nowhere in sight.
    /// Returning the page to 0 whenever focus lands in the browser gives the
    /// browser exactly one resting position no matter which direction it was
    /// entered from.
    ///
    /// Coming down from the hero the page is already at 0, so this is a no-op,
    /// and Season → Episode moves cost nothing either.
    private func revealBrowser(using proxy: ScrollViewProxy) {
        PlozzLog.app.info("PLZGEO focus=browser")
        withAnimation(.smooth(duration: Self.recedeAnimationDuration)) {
            recedeModel.isReceded = true
            proxy.scrollTo(Self.topAnchorID, anchor: .top)
        }
    }

    private func handleHeroFocus(using proxy: ScrollViewProxy) {
        PlozzLog.app.info(
            "PLZGEO focus=hero dupSuppressed=\(suppressesDuplicateHeroFocus)"
        )
        guard !suppressesDuplicateHeroFocus else { return }
        rearmEpisodeRailOnHeroFocusIfNeeded()
        seasonBarEngaged = false
        suppressesDuplicateHeroFocus = true
        withAnimation(.smooth(duration: Self.recedeAnimationDuration)) {
            recedeModel.isReceded = false
            proxy.scrollTo(Self.topAnchorID, anchor: .top)
        }
        DispatchQueue.main.async {
            suppressesDuplicateHeroFocus = false
        }
    }

    // MARK: Season tabs

    private func seasonTabBar(onFocusEntered: @escaping () -> Void) -> some View {
        let hasRequestAccessory = requestAvailability?.hasSeasonRequestContent == true
        return ScrollViewReader { proxy in
            if hasRequestAccessory {
                HStack(spacing: 18) {
                    if !seasons.isEmpty {
                        seasonScroller(
                            using: proxy,
                            hasRequestAccessory: true,
                            onFocusEntered: onFocusEntered
                        )
                        .frame(maxWidth: .infinity)
                    } else {
                        Spacer(minLength: PlozzTheme.Metrics.heroLeadingPadding)
                    }

                    seasonRequestMenu(onFocusEntered: onFocusEntered)
                        .padding(.trailing, PlozzTheme.Metrics.screenPadding)
                }
                .frame(height: SeriesEpisodeBrowserLayout.seasonBarHeight)
                .focusSection()
            } else {
                // Preserve the original season rail geometry from 2593bfa4:
                // selected seasons are measured in this viewport and minimally
                // revealed to its trailing edge. Wrapping this in the accessory
                // HStack changed that geometry and regressed long-show entry.
                seasonScroller(
                    using: proxy,
                    hasRequestAccessory: false,
                    onFocusEntered: onFocusEntered
                )
                    .frame(height: SeriesEpisodeBrowserLayout.seasonBarHeight)
                    .focusSection()
            }
        }
    }

    private func seasonScroller(
        using proxy: ScrollViewProxy,
        hasRequestAccessory: Bool,
        onFocusEntered: @escaping () -> Void
    ) -> some View {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(seasons) { season in
                        seasonChip(season)
                    }
                    // (No trailing spacer: we no longer leading-align chips, so the
                    // last chip should sit at the natural right edge — the phantom
                    // full-viewport spacer used to be what let an already-visible bar
                    // be shifted at all.)
                }
                .padding(
                    .trailing,
                    hasRequestAccessory
                        ? PlozzTheme.Metrics.screenPadding + SeriesEpisodeBrowserLayout.seasonRequestFadeWidth
                        : PlozzTheme.Metrics.screenPadding
                )
                .padding(.leading, hasRequestAccessory ? PlozzTheme.Metrics.heroLeadingPadding : 0)
                // Headroom for the focused chip's lift so it is never clipped.
                .padding(.vertical, 12)
            }
            // Anchor a coordinate space to the scroll VIEWPORT so each season chip's
            // frame reflects the live scroll offset — the visible region is exactly
            // `0...seasonBarViewportWidth`. Attached to the raw ScrollView (before the
            // leading inset below) so `minX == 0` at the keyline and the measured width
            // is the true scroll viewport width.
            .coordinateSpace(name: Self.seasonBarSpace)
            // Measure the scroll viewport's own width (before the external leading
            // inset) — the right edge of the visible region in `seasonBarSpace`.
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear {
                            if seasonBarViewportWidth != geo.size.width {
                                seasonBarViewportWidth = geo.size.width
                            }
                        }
                        .onChange(of: geo.size.width) { _, width in
                            if seasonBarViewportWidth != width {
                                seasonBarViewportWidth = width
                            }
                        }
                }
            )
            // Collect the pending target's frame (published by `seasonChip`) so the
            // reveal can tell whether it is already fully visible and, if not, which
            // edge it is clipped past.
            .onPreferenceChange(SeasonChipFramesKey.self) { frames in
                guard pendingSeasonReveal, frames != seasonChipFrames else { return }
                seasonChipFrames = frames
            }
            .modifier(SeasonRequestBoundaryModifier(
                enabled: hasRequestAccessory
            ))
            .onChange(of: focusedSeasonID) { _, newValue in
                guard let id = newValue else { return }
                let isEntering = !seasonBarEngaged
                // We're now inside the bar — open every chip to focus so left/right
                // navigation between seasons works.
                seasonBarEngaged = true
                // User-driven focus: fence the opening Play claim (see
                // `hasSettledOpeningFocus`) so it can't fire behind them.
                hasUserDirectedFocus = true
                hasSettledOpeningFocus = true
                if isEntering { onFocusEntered() }
                // Focus has genuinely left the episode rail (it's now on the bar), so
                // tell the rail to re-arm its entry gate for the next down-press.
                episodeRailResetToken += 1
                guard let season = seasons.first(where: { $0.id == id }) else { return }
                select(season)
                // Deliberately *don't* move the hero to the season: focusing the tab bar
                // keeps the page on the episode you were last viewing, so going up and
                // back down stays anchored to that episode rather than the season.
            }
            // Reveal the active season chip ONLY when it is actually off-screen, and
            // then MINIMALLY — flush to whichever edge it was clipped past — rather
            // than leading-aligning it under the Play button (see
            // `fulfilSeasonRevealIfPending`). Armed on arrival and on an external
            // re-selection (e.g. a cross-server switch); consumed once geometry is
            // measured. We deliberately do NOT re-anchor when focus merely leaves the
            // bar, and never while `seasonBarEngaged` (so it can't fight tvOS while the
            // user is navigating the bar) — once the user has scrolled the bar it
            // stays where they left it.
            .onAppear {
                seasonChipFrames = [:]
                pendingSeasonReveal = true
                fulfilSeasonRevealIfPending(using: proxy)
            }
            .onChange(of: selectedSeasonID) { _, _ in
                guard !seasonBarEngaged else { return }
                seasonChipFrames = [:]
                pendingSeasonReveal = true
                fulfilSeasonRevealIfPending(using: proxy)
            }
            // Frames and viewport width settle a layout pass after the bar appears, so
            // run the (idempotent, one-shot) reveal as soon as real measurements exist.
            .onChange(of: seasonChipFrames) { _, _ in fulfilSeasonRevealIfPending(using: proxy) }
            .onChange(of: seasonBarViewportWidth) { _, _ in fulfilSeasonRevealIfPending(using: proxy) }
    }

    private func seasonRequestMenu(onFocusEntered: @escaping () -> Void) -> some View {
        let hasRequestable = !(requestAvailability?.requestableSeasonNumbers.isEmpty ?? true)
        return SeasonRequestMenu(
            availability: requestAvailability ?? MediaRequestAvailability(status: .unknown),
            requestAllTitle: "Request All Missing Seasons",
            onRequest: { onRequestSeasons?($0) }
        ) {
            Label(
                SeriesRequestAccessoryPresentation.title(
                    hasRequestable: hasRequestable,
                    isRequesting: isRequestingSeasons
                ),
                systemImage: SeriesRequestAccessoryPresentation.systemImage(
                    hasRequestable: hasRequestable,
                    isRequesting: isRequestingSeasons
                )
            )
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .menuStyle(.button)
        .buttonStyle(PlozzSeasonTabStyle(isSelected: false))
        .focusEffectDisabled()
        .focused($requestSeasonsFocused)
        // Before the active season receives focus, remove this geometrically-near
        // trailing control so DOWN from the hero cannot skip the active season.
        .disabled(!SeriesRequestFocusPolicy.accessoryEnabled(
            hasOwnedSeasons: !seasons.isEmpty,
            seasonBarEngaged: seasonBarEngaged,
            hasRequestHandler: onRequestSeasons != nil && !isRequestingSeasons
        ))
        .onChange(of: requestSeasonsFocused) { _, focused in
            if focused {
                let isEntering = !seasonBarEngaged
                seasonBarEngaged = true
                hasUserDirectedFocus = true
                hasSettledOpeningFocus = true
                if isEntering { onFocusEntered() }
                episodeRailResetToken += 1
            }
        }
    }

    /// Reveals the active season chip **only when it is actually off-screen**, and
    /// then **minimally** — flush to whichever edge it was clipped past — rather than
    /// leading-aligning it under the Play button. A no-op when the chip is already
    /// fully visible (e.g. a 2–3 season bar that all fits). One-shot per arm via
    /// `pendingSeasonReveal`, and only ever runs once real geometry is measured, so it
    /// can neither prematurely leading-align nor loop on its own animated scroll.
    ///
    /// A genuinely off-screen active season (e.g. Season 12 on a long show) is still
    /// brought into view; it stays reachable by a down-press from Play via the season
    /// bar's disabled-others gate + `.focusSection()`, not by leading-alignment.
    private func fulfilSeasonRevealIfPending(using proxy: ScrollViewProxy) {
        guard pendingSeasonReveal, !seasonBarEngaged else { return }
        guard let id = selectedSeasonID ?? seasons.first?.id else { return }
        // Wait until both the viewport and the target chip have been measured.
        guard seasonBarViewportWidth > 0, let frame = seasonChipFrames[id] else { return }

        // We have geometry — consume the arm (whether or not we end up scrolling).
        pendingSeasonReveal = false

        guard let edge = SeriesSeasonRevealEdge.clippedEdge(
            frame: frame,
            viewportWidth: seasonBarViewportWidth,
            clearance: PlozzTheme.Metrics.screenVerticalPadding
        ) else { return }
        let anchor = edge.revealAnchor(
            targetWidth: frame.width,
            viewportWidth: seasonBarViewportWidth,
            clearance: PlozzTheme.Metrics.screenVerticalPadding
        )
        DispatchQueue.main.async {
            if reduceMotion {
                proxy.scrollTo(id, anchor: anchor)
            } else {
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(id, anchor: anchor)
                }
            }
        }
    }

    /// A single season tab. It reads as text-only until focused or active, then
    /// lifts into a Liquid-glass pill (matching the Twozz player controls). The
    /// style is applied unconditionally so selection never changes the tab's
    /// identity — that is what keeps left/right focus moving between tabs.
    private func seasonChip(_ season: MediaItem) -> some View {
        let isSelected = selectedSeasonID == season.id
        // The chip focus can land on while *entering* the bar: the active season,
        // falling back to the first one before a selection settles, so the bar is
        // never momentarily unfocusable during initial load.
        let activeID = selectedSeasonID ?? seasons.first?.id
        let isFocusable = seasonBarEngaged || season.id == activeID
        return Button {
            select(season)
        } label: {
            Text(season.title)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(PlozzSeasonTabStyle(isSelected: isSelected))
        // No system focus ring — the pill + scale is the focus treatment.
        .focusEffectDisabled()
        .focused($focusedSeasonID, equals: season.id)
        // Stable scroll target so the season bar can programmatically scroll the
        // active chip into view (see `fulfilSeasonRevealIfPending`).
        .id(season.id)
        // Measure only the pending reveal target. Once the one-shot decision is
        // consumed, no chip publishes live scroll frames, so horizontal movement
        // cannot invalidate the full series page on every animation frame.
        .background {
            if pendingSeasonReveal, season.id == activeID {
                GeometryReader { geo in
                    Color.clear.preference(
                        key: SeasonChipFramesKey.self,
                        value: [season.id: geo.frame(in: .named(Self.seasonBarSpace))]
                    )
                }
            }
        }
        // Remove non-active seasons from the focus system until the bar is engaged,
        // so directional entry can only ever land on the active season (no snap).
        .disabled(!isFocusable)
    }

    /// Selects `season`: marks it active and kicks off (cached) episode loading
    /// so the rail and Play target are ready as focus settles on the tab.
    private func select(_ season: MediaItem) {
        selectedSeasonID = season.id
        Task {
            await viewModel.loadEpisodes(for: season.id)
            updateRailTarget()
        }
    }

    /// Re-points the rail's stable entry target (`railTargetID`) at a discrete
    /// moment — open, season change, or a cross-server switch. Prefers the fronted
    /// episode when it lives in the current season pool (a tapped/switched-to
    /// episode), else the season's next-up. Deliberately NOT called as focus moves
    /// through the rail, so browsing never changes `defaultFocusID` (which would
    /// re-arm the rail gate and make scrolling janky).
    @MainActor
    private func updateRailTarget() {
        let pool = currentEpisodes
        if heroItem.kind == .episode, pool.contains(where: { $0.id == heroItem.id }) {
            railTargetID = heroItem.id
        } else {
            railTargetID = SeriesResume.nextUp(in: pool)?.id
        }
    }

    // MARK: Episode rail

    @ViewBuilder
    private func episodeRail(onFocusEntered: @escaping () -> Void) -> some View {
        if let selectedSeasonID,
           viewModel.episodes(for: selectedSeasonID) == nil {
            SeriesEpisodeSkeletonRail()
        } else {
        // Owned episodes first, then the season's not-yet-aired ones so a viewer can
        // see (and read about) the rest of the run without leaving the page.
        let episodes = currentEpisodes + upcomingPlaceholders
        // The episode focus should land on when entering the rail / where it
        // pre-scrolls. We use the STABLE `railTargetID` (updated only on open,
        // season change, or a cross-server switch) rather than the live
        // `heroItem`/`playTarget`, which change as the user browses cards — keying
        // the rail's default focus on that re-armed its entry gate every card and
        // made scrolling snap back. On a normal open this still resolves to the
        // originally-targeted episode / next-up; after an in-place switch it is
        // re-pointed to the preserved episode on the new server (new per-server id).
        // MediaRowView re-scrolls via .onChange(of: defaultFocusID) when it changes.
        // The episode array is published before `resolveRestingHero` resumes and
        // stores `railTargetID`. On a huge single season that one actor turn used
        // to render episodes 1–50, then replace the window with the target-centered
        // 50 when the id arrived — the apparent post-arrival "renegotiation".
        // Resolve the same fallback synchronously from the final episode pool so
        // the rail's very first frame already uses its permanent target.
        let entryTarget = SeriesEpisodeEntry.episode(
            matching: initialEpisode,
            in: currentEpisodes
        )?.id
        let stableTarget = railTargetID.flatMap { id in
            currentEpisodes.contains(where: { $0.id == id }) ? id : nil
        }
        let target = entryTarget
            ?? stableTarget
            ?? SeriesResume.nextUp(in: currentEpisodes)?.id
        SeriesWindowedEpisodeRail(
            title: railTitle,
            episodes: episodes,
            spoilerSettings: spoilerSettings,
            targetID: target,
            initialFocusID: initialEpisode == nil ? nil : target,
            focusResetToken: episodeRailResetToken,
            isCovered: hasChildOnTop,
            precedingContainerIDs: precedingSeasonIDs,
            onRefocusComplete: {
                isReclaimingFocus = false
            },
            onFocusEntered: {
                seasonBarEngaged = false
                // The user has taken focus into the rail themselves — the opening
                // Play claim must not fire behind them.
                hasUserDirectedFocus = true
                hasSettledOpeningFocus = true
                onFocusEntered()
            },
            onSelect: { item in
                // An unaired episode has nothing to play and no page worth opening,
                // so selecting it is deliberately inert — it stays focusable purely
                // so the rest of the run can be browsed and read.
                guard !item.isUpcomingUnaired else { return }
                onPlay(item)
            }
        )
        }
    }

    /// The ids of seasons that come before the one whose rail is showing, so
    /// "mark watched up to here" can also clear every earlier season in full.
    private var precedingSeasonIDs: [String] {
        guard let id = selectedSeasonID,
              let current = seasons.first(where: { $0.id == id }),
              let currentNumber = current.seasonNumber else { return [] }
        return seasons
            .filter { ($0.seasonNumber ?? .max) < currentNumber }
            .map(\.id)
    }

    /// Identifies the currently-loaded episode set for the still prefetch task, so
    /// it fires once the selected season's episodes arrive and again when the
    /// season changes — but not on every unrelated re-render.
    private var stillPrefetchKey: String {
        "\(series.sourceAccountID ?? "_")#\(series.id)#\(selectedSeasonID ?? "loose")#\(currentEpisodes.count)"
    }

    private var seasonSetKey: String {
        let seasonIDs = seasons.map(\.id).joined(separator: ",")
        return "\(series.sourceAccountID ?? "_")#\(series.id)#\(seasonIDs)"
    }

    /// Warms the **currently selected** season so its episode thumbnails are
    /// synchronously seedable on first render (no gray placeholder flash). Runs
    /// whenever the selected season's episodes arrive or change.
    private func prefetchSeasonStills() async {
        if let id = selectedSeasonID {
            await warmSeason(id)
        } else {
            warmPrimaryThumbnails(for: currentEpisodes)
        }
    }

    /// Background-warms the nearest seasons after the visible season has settled.
    /// Bounded so long multi-season shows do not decode their entire catalog.
    private func prewarmAllSeasons() async {
        try? await Task.sleep(for: .seconds(2.5))
        if Task.isCancelled { return }
        let selectedIndex = seasons.firstIndex { $0.id == selectedSeasonID } ?? 0
        let neighbors = seasons.enumerated()
            .filter { $0.element.id != selectedSeasonID }
            .sorted { abs($0.offset - selectedIndex) < abs($1.offset - selectedIndex) }
            .prefix(Self.prewarmSeasonWindow)
            .map(\.element)
        for season in neighbors {
            if Task.isCancelled { return }
            await viewModel.loadEpisodes(for: season.id)
            await warmSeason(season.id)
            await Task.yield()
        }
    }

    private static let prewarmSeasonWindow = 4

    /// Makes a season's episode thumbnails render with **no gray flash** when its
    /// rail appears, by guaranteeing each card can seed its image *synchronously*
    /// from the decoded cache on first frame.
    ///
    /// Two episode shapes exist:
    ///   • Episodes the server has an image for already expose a seedable candidate
    ///     URL (`posterURL`/`backdropURL`); we just decode it into the cache.
    ///   • Anime (and other) episodes the server has *no* image for would otherwise
    ///     get their still from the asynchronous ``ArtworkRouter`` fallback — a URL
    ///     that is resolved lazily and therefore can **never** be seeded
    ///     synchronously, which is the root of the persistent one-frame gray flash.
    ///     For those we resolve the still here (the real per-episode still, else the
    ///     series hero), decode it, and **inject it as the episode's `posterURL`**
    ///     so it becomes a seedable candidate. The enriched episodes are handed back
    ///     to the view model so the rail re-renders seeding the now-decoded image.
    private func warmSeason(_ seasonID: String) async {
        guard let episodes = viewModel.episodes(for: seasonID) else { return }
        var resolvedPosterURLs: [String: URL] = [:]
        var heroResolved = false
        var heroURL: URL?
        for episode in episodes {
            if Task.isCancelled { return }
            let candidates = MediaArtworkPrefetchPolicy.candidates(
                for: episode,
                style: .landscape,
                spoilerSettings: spoilerSettings
            )
            if let url = candidates.first {
                #if canImport(UIKit)
                await ArtworkSession.warmLimiter.run {
                    _ = await ArtworkImageCache.shared.image(for: url, variant: .landscapeCard, background: true)
                }
                #endif
                continue
            }
            guard !(spoilerSettings.mode == .placeholder
                    && spoilerSettings.shouldHideThumbnail(for: episode)) else { continue }
            guard episode.kind == .episode else { continue }
            // No server image: resolve a real still, falling back to the series
            // hero (resolved once and reused) so every episode is at least covered.
            var still = await ArtworkRouter.shared.artworkURL(.thumbnail, for: episode)
            if Task.isCancelled { return }
            if still == nil {
                if !heroResolved {
                    heroURL = await ArtworkRouter.shared.artworkURL(.hero, for: series)
                    if Task.isCancelled { return }
                    heroResolved = true
                }
                still = heroURL ?? series.fallbackArtworkURL
            }
            guard let still else { continue }
            #if canImport(UIKit)
            await ArtworkSession.warmLimiter.run {
                _ = await ArtworkImageCache.shared.image(for: still, variant: .landscapeCard, background: true)
            }
            #endif
            if Task.isCancelled { return }
            resolvedPosterURLs[episode.id] = still
        }
        viewModel.mergeResolvedEpisodePosterURLs(resolvedPosterURLs, for: seasonID)
    }

    /// Decodes each episode's first displayed landscape candidate (its server
    /// image) into the shared synchronous image cache. Used for the loose-episode
    /// case where there is no season id to enrich.
    private func warmPrimaryThumbnails(for episodes: [MediaItem]) {
        #if canImport(UIKit)
        for episode in episodes {
            guard let url = MediaArtworkPrefetchPolicy.candidates(
                for: episode,
                style: .landscape,
                spoilerSettings: spoilerSettings
            ).first else { continue }
            ArtworkImageCache.shared.prefetch(url, variant: .landscapeCard)
        }
        #endif
    }

    /// Episodes the rail should show: the selected season's loaded episodes, or
    /// the series' loose episodes when there are no season containers.
    private var currentEpisodes: [MediaItem] {
        if let id = selectedSeasonID, let episodes = viewModel.episodes(for: id) {
            return episodes
        }
        return seasons.isEmpty ? stampedLooseEpisodes : []
    }

    /// The selected season's unaired episodes, as non-playable rail entries.
    private var upcomingPlaceholders: [MediaItem] {
        guard let schedule = viewModel.state.value?.upcomingSchedule,
              !schedule.upcomingEpisodes.isEmpty else { return [] }
        let seasonNumber = selectedSeasonID
            .flatMap { id in seasons.first { $0.id == id } }?
            .seasonNumber
        return SeriesUpcoming.placeholders(
            for: seasonNumber,
            seriesID: series.id,
            seriesTitle: series.title,
            ownedEpisodes: currentEpisodes,
            schedule: schedule.upcomingEpisodes,
            seriesArtwork: series
        )
    }

    /// The hero's air-schedule line, e.g. "New episodes Fridays".
    private var upcomingHeroLine: LocalizedStringResource? {
        guard let schedule = viewModel.state.value?.upcomingSchedule else { return nil }
        return SeriesUpcoming.heroLine(
            nextEpisode: schedule.upcomingEpisode,
            cadence: schedule.cadence,
            schedule: schedule.upcomingEpisodes
        )
    }

    private var revealsCastWithoutBrowser: Bool {
        SeriesDetailBrowserPolicy.revealsCastWithoutBrowser(
            childrenLoaded: viewModel.state.value?.childrenLoaded == true,
            hasSeasons: !seasons.isEmpty,
            hasEpisodes: !currentEpisodes.isEmpty
        )
    }

    private func rearmEpisodeRailOnHeroFocusIfNeeded() {
        guard SeriesDetailBrowserPolicy.rearmsEpisodeRailOnHeroFocus(
            hasSeasons: !seasons.isEmpty
        ) else { return }
        episodeRailResetToken &+= 1
    }


    /// Header for the episode rail. A selected season's name is already shown on
    /// its tab/chip above the rail, so the rail itself stays unlabelled to avoid
    /// repeating it. The flat "loose episodes" case (no season tabs) keeps an
    /// "Episodes" header since nothing else names it.
    /// `nil` hides the rail heading — clearer than the empty string this used to
    /// return, now that MediaRowView takes an Optional.
    private var railTitle: Text? {
        if selectedSeasonID != nil { return nil }
        return seasons.isEmpty ? Text("Episodes") : nil
    }

    /// The episode the hero's Play button acts on: the focused episode itself, or
    /// the "next up" episode of the current season. `nil` hides the button.
    /// The hero "…" menu's server-select handler for a series, or `nil` when the
    /// show lives on a single server (no picker) or no switch handler is wired.
    /// Picking a *different* server switches the page to that server's copy IN
    /// PLACE (reloading its seasons/episodes) without navigating, so the back stack
    /// never grows; re-picking the current server is a no-op. Before switching it
    /// captures the fronted episode's season+episode NUMBER so the new server lands
    /// on the SAME episode rather than its own next-up.
    private var serverPickerAction: ((String) -> Void)? {
        guard let onSelectServer,
              Set(viewModel.sources.map(\.accountID)).count > 1 else { return nil }
        return { accountID in
            guard accountID != series.sourceAccountID,
                  let source = viewModel.sources.first(where: { $0.accountID == accountID })
            else { return }
            // Capture the fronted episode by NUMBER (the displayed hero, whose S/E
            // is guaranteed) so the new server fronts the same one after reload.
            let fronted = displayHeroItem
            if fronted.kind == .episode,
               let season = fronted.seasonNumber, let episode = fronted.episodeNumber {
                pendingSwitchTargetSE = SeasonEpisodeRef(season: season, episode: episode)
            } else {
                pendingSwitchTargetSE = nil
            }
            onSelectServer(source)
        }
    }

    /// The play-target episode's selectable versions (qualities/editions on the
    /// current server). Empty or single-entry hides the "…" Version section, so it
    /// only appears when an episode genuinely has more than one file — matching the
    /// movie behaviour.
    private var playVersions: [MediaVersion] {
        playTarget?.versions ?? []
    }

    /// The server-picker list with same-account duplicates collapsed (one entry
    /// per distinct account). Matches the movie/`ItemDetailView` behaviour so a
    /// rare same-server duplicate series doesn't render two identical "Server"
    /// rows in the picker.
    private var distinctServerChoices: [MediaSourceRef] {
        var seen = Set<String>()
        var result: [MediaSourceRef] = []
        for source in viewModel.sources where seen.insert(source.accountID).inserted {
            result.append(source)
        }
        return result
    }

    /// The effective version id the Version section checkmarks and `Play` targets:
    /// the in-session override when it's still valid for this episode, else the
    /// device-recommended pick.
    private var effectivePlayVersionID: String? {
        if let versionOverride, playVersions.contains(where: { $0.id == versionOverride }) {
            return versionOverride
        }
        return playVersions.recommendedSelection(for: .detected())?.id
    }

    /// The technical facts of the file Play would actually run.
    ///
    /// Replaces a peak-across-loaded-episodes summary, which claimed things we
    /// cannot know and changed under the user: only the opening season is loaded
    /// when the page appears, so a show with a 1080p S1 and a 4K S2 read "1080p"
    /// and then flipped to "4K" ~2.5s later as neighbouring seasons warmed. Worse,
    /// it could promise 4K above a Play button that starts a 1080p file.
    ///
    /// Empty until the play target's media info is known — showing nothing beats
    /// showing the wrong thing, the same reasoning the version branch in
    /// `DetailHeroView.featureBadges` already applies.
    private var playTargetTechnicalBadges: [MediaBadge] {
        playTarget?.technicalBadges ?? []
    }

    private var playTarget: MediaItem? {
        if heroItem.kind == .episode { return heroItem }
        // The hero is the show — either nothing is watched or all of it is. Both
        // mean "start from the beginning", so offer the first episode rather than
        // `nextUp`, which returns the *finale* once everything is played.
        let target = SeriesResume.isFinished(seasons: seasons, episodes: currentEpisodes)
            ? currentEpisodes.first
            : SeriesResume.nextUp(in: currentEpisodes)
        guard let target,
              let enriched = restingPlayTargetEnrichment,
              enriched.id == target.id else { return target }
        return enriched
    }

    /// The hero item with its season/episode numbers guaranteed when an episode is
    /// fronted, so the hero ALWAYS shows "S{n} · E{m}" for a TV show. Some list/
    /// search/seed episodes arrive without numbers (they know only their own id);
    /// `SeriesHeroNumbering` backfills them from the loaded episode the rail shows,
    /// the owning season, or the episode's position — never inventing a wrong value.
    private var displayHeroItem: MediaItem {
        SeriesHeroNumbering.numberedHero(
            heroItem,
            seasons: seasons,
            loadedEpisodesBySeason: viewModel.seasonEpisodes,
            selectedSeasonID: selectedSeasonID,
            selectedSeasonPool: currentEpisodes
        )
    }

    /// The series' trailer action, shown only while the hero is presenting the
    /// series itself (not a focused season/episode), so the Trailer button reads
    /// as belonging to the show. `nil` hides the button.
    private var trailerButtonAction: (() -> Void)? {
        guard heroItem.id == series.id, let trailer = viewModel.trailers.first else { return nil }
        return { onPlay(trailer) }
    }

    /// Picks the season to open on first appearance and preloads it. Every entry
    /// point funnels through here: the single, shared resolver `resolvedInitialSeasonID()`
    /// decides which season to land on (explicit hint → else the season you're
    /// actually watching → else the first), so a plain series open no longer
    /// defaults to Season 1 when you're mid-series. When targeting a tapped episode,
    /// swaps the hero to the richer loaded copy of that episode once its season's
    /// episodes are available.
    private func prepareInitialSeason() async {
        // After an in-place cross-server switch, re-front the same S·E episode on
        // the new server (its seasons just loaded under us). Matched by NUMBER
        // because per-server ids differ. Takes priority over the open-time target.
        if let target = pendingSwitchTargetSE {
            pendingSwitchTargetSE = nil
            await frontSwitchTarget(target)
            return
        }
        // No seasons at all (a flat "loose episode" show): just front any target
        // episode and let the loose-episode rail show.
        guard let id = resolvedInitialSeasonID() else {
            await resolveRestingHero(in: nil)
            return
        }
        selectedSeasonID = id
        await viewModel.loadEpisodes(for: id)
        await resolveRestingHero(in: id)
    }

    /// Re-selects the season with `target`'s number on the freshly-switched server
    /// and fronts the matching episode, so an in-place server switch keeps the
    /// user on the same episode. Matching is scoped to the resolved season and
    /// done by `episodeNumber` (with a positional fallback) so it still works when
    /// the new server's episodes don't all carry a `seasonNumber`. When the new
    /// server lacks that episode entirely it falls back to the season's next-up,
    /// and ultimately to the series hero — never leaving the *old* server's
    /// episode fronted (which would mismatch the now-active server). Does not
    /// touch `playFocused`, so focus stays on the "…" menu.
    @MainActor
    private func frontSwitchTarget(_ target: SeasonEpisodeRef) async {
        guard let seasonID = seasons.first(where: { $0.seasonNumber == target.season })?.id
            ?? seasons.first?.id else {
            heroItem = series
            return
        }
        selectedSeasonID = seasonID
        await viewModel.loadEpisodes(for: seasonID)
        let pool = viewModel.episodes(for: seasonID) ?? []
        let positional = (target.episode >= 1 && target.episode <= pool.count) ? pool[target.episode - 1] : nil
        if let match = pool.first(where: { $0.episodeNumber == target.episode }) ?? positional {
            heroItem = match
        } else if let next = SeriesResume.nextUp(in: pool) {
            heroItem = next
        } else {
            heroItem = series
        }
        updateRailTarget()
    }

    /// **The single source of truth for which season the page opens on**, shared by
    /// *every* entry point (they all reach this via `prepareInitialSeason`). The
    /// entry points only differ in which hint they hand `SeriesDetailView`:
    ///
    ///   • a tapped **episode** card (Continue Watching / Recently Added) →
    ///     `EpisodeContextRoute` → `initialEpisode`;
    ///   • a tapped **season** card / "Go to Season" → `SeasonContextRoute` /
    ///     `viewModel.preselectedSeasonID` → `initialSeasonID`;
    ///   • a plain **series tile** (Library / Home / Search) → no season hint.
    ///
    /// Resolution order, most-specific first:
    ///   1. an already-settled selection (e.g. after a season-tab focus);
    ///   2. an explicit `initialSeasonID` (tapped season / "Go to Season");
    ///   3. a tapped episode's own season — by id, or across servers by NUMBER
    ///      (per-server season ids differ);
    ///   4. **no hint:** the season the user is actually *watching* — first
    ///      in-progress, else first unwatched, else last — from the seasons' own
    ///      played state (carried by BOTH Jellyfin and Plex). This is what stops a
    ///      mid-series show from wrongly opening on Season 1.
    ///   5. ultimately the first season (a brand-new, fully-unwatched show).
    ///
    /// Returns `nil` only when there are no season containers at all (a flat
    /// loose-episode show).
    /// Dumps the watch state the season decision is actually made from.
    ///
    /// The page picks its opening season by asking the season containers which one
    /// the viewer is on, and that answer is only as good as what each backend puts
    /// on a season — where the three disagree sharply. A season whose only
    /// progress is a part-watched episode reports no completed children on either
    /// Jellyfin or Plex, so it can look untouched while an earlier season with
    /// finished episodes looks "in progress". When the page opens somewhere
    /// surprising this is the difference between reading the evidence and guessing
    /// at it.
    private static func logSeasonResolution(_ seasons: [MediaItem], resume: MediaItem?) {
        guard !seasons.isEmpty else { return }
        let summary = seasons.map { season in
            let recency = season.lastPlayedAt.map { String(Int($0.timeIntervalSince1970)) } ?? "nil"
            let percent = season.playedPercentage.map { String(format: "%.2f", $0) } ?? "nil"
            return "S\(season.seasonNumber.map(String.init) ?? "?")"
                + "[played=\(season.isPlayed)"
                + " started=\(season.hasBeenPlayed)"
                + " pct=\(percent)"
                + " inProgress=\(SeriesResume.isInProgress(season))"
                + " last=\(recency)]"
        }.joined(separator: " ")
        let chosen = SeriesResume.nextUp(in: seasons)?.seasonNumber.map(String.init) ?? "nil"
        let server = resume.map { "S\($0.seasonNumber.map(String.init) ?? "?")E\($0.episodeNumber.map(String.init) ?? "?")" } ?? "nil"
        PlozzLog.app.debug("seasonResolution serverResume=\(server) inferred=S\(chosen) \(summary)")
    }

    private func resolvedInitialSeasonID() -> String? {
        Self.logSeasonResolution(seasons, resume: viewModel.serverResumeEpisode)
        if let id = selectedSeasonID, seasons.contains(where: { $0.id == id }) { return id }
        if let id = initialSeasonID, seasons.contains(where: { $0.id == id }) { return id }
        if let id = initialEpisode?.seasonID, seasons.contains(where: { $0.id == id }) { return id }
        if let number = initialEpisode?.seasonNumber,
           let match = seasons.first(where: { $0.seasonNumber == number }) {
            return match.id
        }
        // The server's own answer, from the same Continue Watching feed the Home
        // rail uses. It outranks anything inferred from the season containers,
        // which on a real library came back with no watch state at all — no
        // played flag, no percentage, no recency — leaving the inference to fall
        // through to "the first season in the list".
        if let resume = viewModel.serverResumeEpisode {
            if let id = resume.seasonID, seasons.contains(where: { $0.id == id }) {
                return id
            }
            if let number = resume.seasonNumber,
               let match = seasons.first(where: { $0.seasonNumber == number }) {
                return match.id
            }
        }
        // No explicit hint (plain series open): land on the season the user is
        // watching, using the same next-up rule the rest of the app uses, applied
        // to the seasons themselves. Never Season 1 unless it genuinely is next up.
        //
        // A **finished** show is the exception: `nextUp` falls through to the last
        // season when everything is watched, which would open on the finale. A
        // finished series starts over instead — behaviourally identical to one
        // never started — so it opens on the first real season. `restartSeason`
        // skips specials, because season 0 sorts ahead of season 1 and "start
        // from the beginning" should not land on a Christmas special.
        if SeriesResume.isFinished(seasons: seasons, episodes: stampedLooseEpisodes) {
            return SeriesResume.restartSeason(in: seasons)?.id ?? seasons.first?.id
        }
        if let resume = SeriesResume.nextUp(in: seasons) { return resume.id }
        return seasons.first?.id
    }

    /// Settles what the hero describes, once the episodes it needs are loaded.
    ///
    /// The hero is the subject of the Play button, so it follows **watch state**,
    /// not focus: the episode to resume when there is one, the show itself when
    /// there is not — either because nothing has been watched, or because all of
    /// it has and the pointer is stale.
    ///
    /// A tapped episode outranks that. Arriving from Continue Watching is an
    /// explicit request for *that* episode, so it is fronted even if the resume
    /// point has since moved.
    ///
    /// Only ever resolves from an **authoritative** pool. A failed fetch caches an
    /// empty list, and acting on that would pin the show fallback with no playable
    /// target until the page was closed.
    @MainActor
    private func resolveRestingHero(in seasonID: String?) async {
        let loadState = seasonID.map { viewModel.seasonLoadState(for: $0) }
        let pool: [MediaItem]
        if let loadState {
            guard let authoritative = loadState.authoritativeEpisodes else { return }
            pool = authoritative
        } else {
            pool = seasons.isEmpty ? stampedLooseEpisodes : []
        }

        if let resume = viewModel.serverResumeEpisode,
                  let loaded = SeriesEpisodeEntry.episode(
                      matching: resume,
                      in: pool
                  ) {
            // The server named the episode to resume; prefer the loaded copy so
            // the hero carries full metadata and badges.
            heroItem = loaded
        } else {
            guard !pool.isEmpty else { return }
            heroItem = SeriesResume.restingHero(
                series: series,
                seasons: seasons,
                episodes: pool
            )
        }
        updateRailTarget()
    }

}

private struct SeriesWindowedEpisodeRail: View {
    let title: Text?
    let episodes: [MediaItem]
    let spoilerSettings: SpoilerSettings
    let targetID: String?
    let initialFocusID: String?
    let focusResetToken: Int
    let isCovered: Bool
    let precedingContainerIDs: [String]
    let onRefocusComplete: () -> Void
    let onFocusEntered: () -> Void
    let onSelect: (MediaItem) -> Void

    @State private var windowRange: Range<Int>?

    var body: some View {
        let visibleEpisodes = Array(episodes[resolvedWindow])
        MediaRowView(
            title: title,
            items: visibleEpisodes,
            presentation: .episodeColumn,
            spoilerSettings: spoilerSettings,
            initialFocusID: initialFocusID,
            initialScrollID: targetID,
            defaultFocusID: targetID,
            focusResetToken: focusResetToken,
            isCovered: isCovered,
            onRefocusComplete: onRefocusComplete,
            leadingInset: PlozzTheme.Metrics.heroLeadingPadding,
            onFocusEntered: onFocusEntered,
            onFocusChange: { item in
                if let item {
                    expandWindow(around: item.id)
                }
            },
            onSelect: onSelect
        )
        .mediaItemActionContext(
            MediaItemActionContext(
                orderedSiblings: episodes,
                precedingContainerIDs: precedingContainerIDs
            )
        )
        .onChange(of: targetID) { _, _ in
            windowRange = nil
        }
    }

    private var resolvedWindow: Range<Int> {
        guard !episodes.isEmpty else { return episodes.indices }
        let targetIndex = targetID.flatMap { id in
            episodes.firstIndex(where: { $0.id == id })
        }
        let storedRangeIsValid = windowRange.map { range in
            range.lowerBound >= episodes.startIndex
                && range.lowerBound < episodes.endIndex
                && range.upperBound <= episodes.endIndex
                && targetIndex.map(range.contains) != false
        } ?? false
        let range = storedRangeIsValid ? windowRange! : initialWindow
        let lower = Swift.max(range.lowerBound, episodes.startIndex)
        let upper = Swift.min(range.upperBound, episodes.endIndex)
        return lower..<upper
    }

    private var initialWindow: Range<Int> {
        let windowSize = 50
        guard episodes.count > windowSize else { return episodes.indices }
        let targetIndex = targetID
            .flatMap { id in episodes.firstIndex(where: { $0.id == id }) }
            ?? episodes.startIndex
        let lower = Swift.min(
            Swift.max(episodes.startIndex, targetIndex - windowSize / 2),
            episodes.endIndex - windowSize
        )
        return lower..<(lower + windowSize)
    }

    private func expandWindow(around itemID: String) {
        guard episodes.count > 50,
              let index = episodes.firstIndex(where: { $0.id == itemID }) else {
            return
        }
        var range = windowRange ?? initialWindow
        if index - range.lowerBound <= 8 {
            range = Swift.max(episodes.startIndex, range.lowerBound - 25)..<range.upperBound
        }
        if range.upperBound - index <= 8 {
            range = range.lowerBound..<Swift.min(episodes.endIndex, range.upperBound + 25)
        }
        if range != windowRange {
            windowRange = range
        }
    }
}

private struct SeriesEpisodeSkeletonRail: View {
    private let metrics = PlozzMetrics.standard

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: metrics.cardSpacing) {
                ForEach(0..<4, id: \.self) { _ in
                    SeriesEpisodeSkeletonCard()
                }
            }
            .padding(.leading, PlozzTheme.Metrics.heroLeadingPadding)
            .padding(.trailing, PlozzTheme.Metrics.screenPadding)
            .padding(.vertical, metrics.railShadowClearance)
        }
        .padding(.top, metrics.railTopClearanceOffset)
        .padding(.bottom, metrics.railBottomClearanceOffset)
        .scrollDisabled(true)
        .accessibilityLabel("Loading episodes")
    }
}

private struct SeriesEpisodeSkeletonCard: View {
    @Environment(\.themePalette) private var palette
    private let metrics = PlozzMetrics.standard

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RoundedRectangle(
                cornerRadius: metrics.landscapeCardCornerRadius,
                style: .continuous
            )
            .fill(palette.fill)
            .frame(
                width: EpisodeColumnCard.artworkSize.width,
                height: EpisodeColumnCard.artworkSize.height
            )
            .plozzMediaEdge(cornerRadius: metrics.landscapeCardCornerRadius)

            VStack(alignment: .leading, spacing: 10) {
                skeletonLine(width: 250, height: 20)
                skeletonLine(width: 440, height: 15)
                skeletonLine(width: 390, height: 15)
                skeletonLine(width: 310, height: 15)
            }
            .padding(.top, metrics.landscapeCaptionTopSpacing)
        }
        .frame(width: EpisodeColumnCard.artworkSize.width, alignment: .leading)
        .padding(.horizontal, EpisodeColumnCard.sideMargin)
        .shimmering()
    }

    private func skeletonLine(width: CGFloat, height: CGFloat) -> some View {
        Capsule()
            .fill(palette.fill)
            .frame(width: width, height: height)
    }
}

enum SeriesDetailBrowserPolicy {
    static func rearmsEpisodeRailOnHeroFocus(hasSeasons: Bool) -> Bool {
        !hasSeasons
    }

    static func revealsCastWithoutBrowser(
        childrenLoaded: Bool,
        hasSeasons: Bool,
        hasEpisodes: Bool
    ) -> Bool {
        childrenLoaded && !hasSeasons && !hasEpisodes
    }
}

enum SeriesDetailEntryPolicy {
    static func claimsHeroPlay(
        hasOpenedOnce: Bool,
        hasInitialEpisode: Bool
    ) -> Bool {
        !hasOpenedOnce && !hasInitialEpisode
    }
}

enum SeriesRequestFocusPolicy {
    static func accessoryEnabled(
        hasOwnedSeasons: Bool,
        seasonBarEngaged: Bool,
        hasRequestHandler: Bool
    ) -> Bool {
        hasRequestHandler && (!hasOwnedSeasons || seasonBarEngaged)
    }

}

enum SeriesRequestAccessoryPresentation {
    static func title(hasRequestable: Bool, isRequesting: Bool) -> LocalizedStringResource {
        if isRequesting { return "Requesting…" }
        return hasRequestable ? "Request More" : "Season Requests"
    }

    static func systemImage(hasRequestable: Bool, isRequesting: Bool) -> String {
        hasRequestable && !isRequesting ? "plus.circle" : "clock.arrow.circlepath"
    }
}

enum SeasonRequestHeroPresentation {
    static func inactiveTitle(availabilityLoaded: Bool, resolved: Bool) -> LocalizedStringResource {
        if availabilityLoaded { return "No Seasons to Request" }
        return resolved ? "Seasons Unavailable" : "Loading Seasons…"
    }
}

private struct SeasonRequestBoundaryModifier: ViewModifier {
    let enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            // A fixed request control owns the trailing edge: contain the tabs and
            // soften that boundary so labels never render beneath the accessory.
            content
                .scrollClipDisabled(false)
                .mask {
                    HStack(spacing: 0) {
                        LinearGradient(
                            colors: [.clear, .white],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: SeriesEpisodeBrowserLayout.seasonRequestFadeWidth)
                        Rectangle()
                            .fill(.white)
                        LinearGradient(
                            colors: [.white, .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: SeriesEpisodeBrowserLayout.seasonRequestFadeWidth)
                    }
                }
        } else {
            // Exact pre-request rail geometry: the viewport begins at the hero
            // keyline and allows focused pills to overflow its bounds.
            content
                .scrollClipDisabled()
                .padding(.leading, PlozzTheme.Metrics.heroLeadingPadding)
        }
    }
}

/// The one season-request menu used by both a playable series' fixed "+ Seasons"
/// accessory and a wholly absent discovery series' hero action.
struct SeasonRequestMenu<MenuLabel: View>: View {
    let availability: MediaRequestAvailability
    let requestAllTitle: String
    let onRequest: ([Int]) -> Void
    @ViewBuilder let label: () -> MenuLabel

    private var pickerSeasons: [MediaSeasonRequestState] {
        availability.requestPickerSeasons
    }

    private var requestableSeasons: [MediaSeasonRequestState] {
        pickerSeasons.filter(\.isRequestable)
    }

    var body: some View {
        Menu {
            if requestableSeasons.count > 1 {
                Button(requestAllTitle) {
                    onRequest(requestableSeasons.map(\.number))
                }
                Divider()
            }
            ForEach(pickerSeasons) { season in
                if season.requestFailed {
                    Button {
                    } label: {
                        Label("\(season.title) — Failed", systemImage: "exclamationmark.circle")
                    }
                    .disabled(true)
                } else if season.isRequestable {
                    Button("Request \(season.title)") {
                        onRequest([season.number])
                    }
                } else {
                    Button {
                    } label: {
                        Label {
                            Text(verbatim: "\(season.title) — ")
                                + Text(season.status == .processing ? "Processing" : "Requested")
                        } icon: {
                            Image(systemName: season.status == .processing ? "arrow.down.circle" : "clock")
                        }
                    }
                    .disabled(true)
                }
            }
        } label: {
            label()
        }
    }
}

enum SeriesSeasonRevealEdge: Equatable {
    case leading
    case trailing

    static func clippedEdge(
        frame: CGRect,
        viewportWidth: CGFloat,
        clearance: CGFloat = 0,
        tolerance: CGFloat = 0.5
    ) -> Self? {
        guard viewportWidth > 0 else { return nil }
        if frame.minX >= clearance - tolerance,
           frame.maxX <= viewportWidth - clearance + tolerance {
            return nil
        }
        return frame.maxX > viewportWidth - clearance ? .trailing : .leading
    }

    /// Unit-point anchor that leaves `clearance` between the revealed chip and
    /// the viewport edge. tvOS applies the same comfort margin when focus lands;
    /// pre-positioning with it prevents a second focus-driven scroll.
    func revealAnchor(
        targetWidth: CGFloat,
        viewportWidth: CGFloat,
        clearance: CGFloat
    ) -> UnitPoint {
        let travel = max(viewportWidth - targetWidth, 1)
        let normalizedClearance = min(max(clearance / travel, 0), 1)
        switch self {
        case .leading:
            return UnitPoint(x: normalizedClearance, y: 0.5)
        case .trailing:
            return UnitPoint(x: 1 - normalizedClearance, y: 0.5)
        }
    }
}

/// Collects the pending season chip's frame (in the season bar's viewport
/// coordinate space) so `SeriesDetailView` can decide whether it is already
/// fully visible — and, if not, which edge it is clipped past for a minimal reveal.
private struct SeasonChipFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

#endif
