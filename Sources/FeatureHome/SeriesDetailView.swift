#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI
import MetadataKit

/// A single, self-contained page for an entire series. The hero at the top is
/// dynamic: it reflects whatever the user is currently *focused* on (not what
/// they've clicked).
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
    /// When the page was opened targeting a specific season, that season's id.
    let initialSeasonID: String?
    /// When the page was opened by tapping a specific episode, that episode. The
    /// page then fronts it in the hero, selects its season, pre-scrolls the
    /// episode row to it, and parks focus on the hero Play button.
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
    /// Drives initial focus onto the hero Play button when the page is opened
    /// targeting a specific episode, so focus lands at the top rather than down
    /// in the episode row.
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
    /// Cosmetic-only series hero recede state. The parent writes it but never reads
    /// it, so episode focus changes do not invalidate this page or its rail.
    @State private var recedeModel = SeriesHeroRecedeModel()

    init(
        series: MediaItem,
        seasons: [MediaItem],
        looseEpisodes: [MediaItem],
        viewModel: ItemDetailViewModel,
        spoilerSettings: SpoilerSettings,
        onPlay: @escaping (MediaItem) -> Void,
        requestAvailability: MediaRequestAvailability? = nil,
        isRequestingSeasons: Bool = false,
        onRequestSeasons: (([Int]) -> Void)? = nil,
        onSelectServer: ((MediaSourceRef) -> Void)? = nil,
        initialSeasonID: String? = nil,
        initialEpisode: MediaItem? = nil
    ) {
        self.series = series
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
        self.initialSeasonID = initialSeasonID
        self.initialEpisode = initialEpisode
        // When opened via "Go to Season", pre-select that season (and front it in
        // the hero) so the page lands on the requested season rather than the
        // default one. When opened by tapping an episode, front that episode and
        // select its season instead.
        let seasonID = initialEpisode?.seasonID ?? initialSeasonID
        let initialSeason = seasonID.flatMap { id in seasons.first { $0.id == id } }
        _selectedSeasonID = State(initialValue: initialSeason?.id)
        _heroItem = State(initialValue: initialEpisode ?? initialSeason ?? series)
        _railTargetID = State(initialValue: initialEpisode?.id)
    }

    /// Scroll anchor for the hero, used to keep the page pinned to the top while
    /// initial focus lands on the bottom-anchored Play button.
    private static let topAnchorID = "series-hero-top"
    /// The episode column's visual-center marker, used identically when focus first
    /// enters either Seasons or Episodes.
    private static let browserFocusAnchorID = "series-episode-browser-focus"

    /// Named coordinate space anchored to the season bar's scroll viewport. In it the
    /// visible region is exactly `0...seasonBarViewportWidth`, so each chip's frame
    /// (published into `seasonChipFrames`) reflects the live scroll offset — letting
    /// us decide true visibility and the clipped edge for a minimal reveal.
    private static let seasonBarSpace = "seasonBarViewport"

    var body: some View {
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
            // Background-warm *every* season's thumbnails the moment the page opens,
            // so switching seasons later is instant (no gray-placeholder flash)
            // rather than fetching that season's stills only once it is selected.
            .task(id: seasonSetKey) { await prewarmAllSeasons() }
            // The hero mirrors the focused episode via a local copy, so when a
            // watched/watchlist mutation broadcasts (e.g. from the hero's own
            // Watched button), flip the same flags on `heroItem` in place so the
            // visible hero button reflects the new state immediately.
            .onReceive(NotificationCenter.default.publisher(for: .mediaItemDidMutate)) { note in
                guard let mutation = MediaItemMutation.from(note) else { return }
                if mutation.targets(heroItem) {
                    heroItem = mutation.applied(to: heroItem)
                } else if heroItem.kind == .episode,
                          mutation.targets(series),
                          let played = mutation.played {
                    heroItem.isPlayed = played
                }
            }
    }

    @ViewBuilder
    private var scrollContent: some View {
        // Always land initial focus on the hero Play button (top) rather than the
        // episode row or a season chip, while the episode rail merely pre-scrolls
        // to the resume/target episode below.
        scroll.defaultFocus($playFocused, true)
    }

    private var scroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    DetailHeroView(
                        item: displayHeroItem,
                        backdropItem: series,
                        titleFallbackOverride: series.title,
                        seriesRecedeModel: recedeModel,
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
                        fallbackTechnicalBadges: representativeTechnicalBadges,
                        playButtonFocus: $playFocused,
                        // Keep the whole hero action row pinned to the top for every
                        // button, not just Play — moving right to Trailer / the "…"
                        // menu / Refresh otherwise lets tvOS's focus-reveal auto-
                        // scroll drift the page down. Same animation as the
                        // Play-regains-focus case below.
                        onHeroActionFocused: {
                            rearmEpisodeRailOnHeroFocusIfNeeded()
                            seasonBarEngaged = false
                            recedeModel.restore()
                            if reduceMotion {
                                proxy.scrollTo(Self.topAnchorID, anchor: .top)
                            } else {
                                withAnimation(.easeInOut(duration: 0.4)) {
                                    proxy.scrollTo(Self.topAnchorID, anchor: .top)
                                }
                            }
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
                    // Proactively enrich the next-up / target episode as soon as it
                    // is known (before the user reaches the rail) so the SERIES
                    // headline badge — a representative max across loaded episodes —
                    // reflects real HDR/DoVi/Atmos instead of the sparse listing,
                    // and the episode is already cached when focus lands on it.
                    .task(id: railTargetID) {
                        guard let id = railTargetID,
                              let target = currentEpisodes.first(where: { $0.id == id }) else { return }
                        _ = await viewModel.enrichEpisodeBadgesIfNeeded(target)
                    }

                    SeriesEpisodeBrowser(
                        series: series,
                        recedeModel: recedeModel,
                        showsSeasons: !seasons.isEmpty || requestAvailability?.hasSeasonRequestContent == true,
                        showsCast: !series.cast.isEmpty,
                        focusAnchorID: Self.browserFocusAnchorID,
                        seasonContent: {
                            // Keep the season chips + "request seasons" button hidden
                            // while focus is up in the hero; reveal them once focus
                            // moves down into the browser (which recedes the hero).
                            // The bar stays in the hierarchy (opacity, not removed) so
                            // pressing down still lands on the active season chip, whose
                            // focus fires the recede that fades the bar in.
                            seasonTabBar {
                                centerEpisodeBrowser(using: proxy)
                            }
                            .opacity(recedeModel.isReceded ? 1 : 0)
                            .animation(
                                reduceMotion ? nil : .easeInOut(duration: 0.3),
                                value: recedeModel.isReceded
                            )
                        },
                        episodeContent: {
                            episodeRail {
                                centerEpisodeBrowser(using: proxy)
                            }
                        }
                    )
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
                        onCastFocusEntered: { seasonBarEngaged = false }
                    )
                        .padding(.top, 32)
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
                if focused {
                    recedeModel.restore()
                    if reduceMotion {
                        proxy.scrollTo(Self.topAnchorID, anchor: .top)
                    } else {
                        withAnimation(.easeInOut(duration: 0.4)) {
                            proxy.scrollTo(Self.topAnchorID, anchor: .top)
                        }
                    }
                }
            }
            .task {
                try? await Task.sleep(nanoseconds: 50_000_000)
                proxy.scrollTo(Self.topAnchorID, anchor: .top)
            }
        }
    }

    /// Moves the episode column to the one final browser position immediately as
    /// focus enters either section. Both entry paths target the same fixed frame,
    /// so Season → Episode has no second vertical movement and rapid DOWN-DOWN
    /// cannot produce a different resting offset from a slow navigation.
    private func centerEpisodeBrowser(using proxy: ScrollViewProxy) {
        recedeModel.recede()
        if reduceMotion {
            proxy.scrollTo(Self.browserFocusAnchorID, anchor: .center)
        } else {
            withAnimation(.smooth(duration: 0.55)) {
                proxy.scrollTo(Self.browserFocusAnchorID, anchor: .center)
            }
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
                recedeModel.recede()
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
                recedeModel.recede()
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

    private func episodeRail(onFocusEntered: @escaping () -> Void) -> some View {
        let episodes = currentEpisodes
        // The episode focus should land on when entering the rail / where it
        // pre-scrolls. We use the STABLE `railTargetID` (updated only on open,
        // season change, or a cross-server switch) rather than the live
        // `heroItem`/`playTarget`, which change as the user browses cards — keying
        // the rail's default focus on that re-armed its entry gate every card and
        // made scrolling snap back. On a normal open this still resolves to the
        // originally-targeted episode / next-up; after an in-place switch it is
        // re-pointed to the preserved episode on the new server (new per-server id).
        // MediaRowView re-scrolls via .onChange(of: defaultFocusID) when it changes.
        let target = railTargetID
        return MediaRowView(
            title: railTitle,
            items: episodes,
            presentation: .episodeColumn,
            spoilerSettings: spoilerSettings,
            // Keep focus on the hero Play button initially; pre-scroll the rail to
            // the resume/target episode and make it the row's default focus so
            // pressing down from Play lands on *that* episode — wherever it is in
            // the season — rather than the geometrically-nearest card.
            initialFocusID: nil,
            initialScrollID: target,
            defaultFocusID: target,
            focusResetToken: episodeRailResetToken,
            leadingInset: PlozzTheme.Metrics.heroLeadingPadding,
            onFocusEntered: {
                seasonBarEngaged = false
                recedeModel.recede()
                onFocusEntered()
            },
            onFocusChange: { focused in
                if let focused, heroItem.id != focused.id { heroItem = focused }
            },
            onSelect: onPlay
        )
        .mediaItemActionContext(
            MediaItemActionContext(
                orderedSiblings: episodes,
                precedingContainerIDs: precedingSeasonIDs
            )
        )
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

    /// Background-warms *every other* season the moment the page opens, which is
    /// what eliminates the gray-placeholder flash when the user later switches
    /// seasons. For each season we first ensure its episodes are fetched and cached
    /// (so the rail never momentarily shows an empty list on switch) and then warm
    /// + inject each episode's thumbnail ahead of time. Seasons are warmed one at a
    /// time, yielding between them, so a long show never floods the loader or
    /// competes with the on-screen season's art. The currently selected season is
    /// skipped here because `prefetchSeasonStills` already owns it.
    private func prewarmAllSeasons() async {
        // Defer the bulk warm so it doesn't flood the (per-host capped) connection
        // pool the instant the page opens and starve the hero backdrop / title logo
        // and the *current* season's stills — the art the user is actually looking
        // at. The current season is already warmed promptly by
        // `prefetchSeasonStills`.
        try? await Task.sleep(for: .seconds(2.5))
        if Task.isCancelled { return }
        // Only pre-warm a WINDOW of seasons nearest the selected one, warmed
        // nearest-first. A long series (e.g. a 20+ season anime) otherwise decoded
        // every season's stills up front — hundreds of landscape thumbnails — for
        // seasons the user may never open, thrashing the decoded-image cache and
        // burning CPU/network on a low-power Apple TV. Seasons outside the window
        // still warm instantly on demand when selected (see `stillPrefetchKey`), so
        // the only cost is a brief thumbnail fetch when jumping to a distant season.
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

    /// How many seasons (nearest the selected one) to pre-warm thumbnails for up
    /// front. Small enough that even a very long series does a bounded amount of
    /// decode work on open, large enough that adjacent-season switches stay
    /// flash-free.
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

    /// A representative tech-badge set (best resolution/HDR/audio) derived from
    /// every episode loaded so far. The series/season hero has no media file of
    /// its own, so this summarises the show's peak capabilities — and because it
    /// aggregates across all loaded seasons, it only grows toward the true peak
    /// as more seasons are browsed.
    private var representativeTechnicalBadges: [MediaBadge] {
        let loaded = viewModel.seasonEpisodes.values.flatMap { $0 }
        let episodes = loaded.isEmpty ? looseEpisodes : loaded
        return episodes.representativeTechnicalBadges
    }

    /// Header for the episode rail. A selected season's name is already shown on
    /// its tab/chip above the rail, so the rail itself stays unlabelled to avoid
    /// repeating it. The flat "loose episodes" case (no season tabs) keeps an
    /// "Episodes" header since nothing else names it.
    private var railTitle: String {
        if selectedSeasonID != nil { return "" }
        return seasons.isEmpty ? "Episodes" : ""
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

    private var playTarget: MediaItem? {
        if heroItem.kind == .episode { return heroItem }
        return SeriesResume.nextUp(in: currentEpisodes)
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
            await frontTargetEpisodeIfNeeded(in: nil)
            return
        }
        selectedSeasonID = id
        await viewModel.loadEpisodes(for: id)
        await frontTargetEpisodeIfNeeded(in: id)
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
    private func resolvedInitialSeasonID() -> String? {
        if let id = selectedSeasonID, seasons.contains(where: { $0.id == id }) { return id }
        if let id = initialSeasonID, seasons.contains(where: { $0.id == id }) { return id }
        if let id = initialEpisode?.seasonID, seasons.contains(where: { $0.id == id }) { return id }
        if let number = initialEpisode?.seasonNumber,
           let match = seasons.first(where: { $0.seasonNumber == number }) {
            return match.id
        }
        // No explicit hint (plain series open): land on the season the user is
        // watching, using the same next-up rule the rest of the app uses, applied
        // to the seasons themselves. Never Season 1 unless it genuinely is next up.
        if let resume = SeriesResume.nextUp(in: seasons) { return resume.id }
        return seasons.first?.id
    }

    /// After episodes load, replace the hero's tapped-episode placeholder with the
    /// fully-loaded episode (richer overview/badges) so the hero and Play target
    /// reflect complete metadata. No-op unless the page is targeting an episode —
    /// a normal open keeps the stable series hero (the Play button still resumes
    /// "next up"), so nothing swaps under the user after load.
    @MainActor
    private func frontTargetEpisodeIfNeeded(in seasonID: String?) async {
        let pool = seasonID.flatMap { viewModel.episodes(for: $0) } ?? (seasons.isEmpty ? stampedLooseEpisodes : [])
        
        if let target = initialEpisode {
            if let loaded = pool.first(where: { $0.id == target.id }) {
                heroItem = loaded
            } else if let season = target.seasonNumber, let episode = target.episodeNumber,
                      let loaded = pool.first(where: {
                          $0.seasonNumber == season && $0.episodeNumber == episode
                      }) {
                // Cross-server switch: per-server episode ids differ, so match the
                // same episode by its season/episode NUMBER on the new server.
                heroItem = loaded
            }
        } else if initialSeasonID != nil {
            if let target = SeriesResume.nextUp(in: pool) {
                heroItem = target
            }
        }
        updateRailTarget()
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
    static func title(hasRequestable: Bool, isRequesting: Bool) -> String {
        if isRequesting { return "Requesting…" }
        return hasRequestable ? "Request More" : "Season Requests"
    }

    static func systemImage(hasRequestable: Bool, isRequesting: Bool) -> String {
        hasRequestable && !isRequesting ? "plus.circle" : "clock.arrow.circlepath"
    }
}

enum SeasonRequestHeroPresentation {
    static func inactiveTitle(availabilityLoaded: Bool, resolved: Bool) -> String {
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
                        Label(
                            "\(season.title) — \(season.status == .processing ? "Processing" : "Requested")",
                            systemImage: season.status == .processing ? "arrow.down.circle" : "clock"
                        )
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
