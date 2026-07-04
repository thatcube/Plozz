#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI
import MetadataKit

/// The Home **hero** carousel: a cinematic, rotating spotlight at the top of
/// Home, functionally near-identical to the Apple TV app. Each slide shows a
/// full-bleed backdrop plus the title logo, metadata and Play / More Info /
/// Watchlist actions.
///
/// Content is whatever the ``HeroCurator`` produced for the user's per-profile
/// ``HeroSettings`` (Continue Watching, Random, Watchlist and — once Seerr lands
/// — Featured). The carousel auto-advances on a timer and pages on the remote
/// per ``HeroCarouselFocus`` (right at the last button advances; left at the
/// first button steps back / escapes to the sidebar).
///
/// The backdrop transition between slides is handled by ``HomeHeroBackdrop``,
/// which performs the Apple TV **parallax wipe imperatively in UIKit (Core
/// Animation)** rather than with any SwiftUI animation — the fix for the
/// long-standing, intermittent wrong-order wipe. Paging is therefore just a state
/// change here (`index` + `lastPageForward`); the backdrop reacts to the fronted
/// slide's id/URLs and entering direction on its own.
struct HomeHeroView: View {
    let items: [MediaItem]
    let settings: HeroSettings
    let spoilerSettings: SpoilerSettings
    let navigationStyle: NavigationStyle
    /// Account-scoped ids of every title currently on the user's watchlist (built
    /// from the loaded Watchlist row). Lets the hero reflect the *series'*
    /// watchlist state on an episode/season slide — whose own `MediaItem` carries
    /// the episode's favourite flag, not the parent show's. Empty = treat all as
    /// not-watchlisted (the safe default).
    var watchlistedKeys: Set<String> = []
    /// Fraction of the screen height the hero occupies. Full-screen, matching the
    /// Apple TV app: the backdrop fills the display top-to-bottom and the Continue
    /// Watching row is pulled up to peek just below the paging dots (see
    /// `HomeView.heroRowOverlap`), rather than the hero being shortened.
    var heroHeightFraction: CGFloat = 1.0
    /// The Home focus scope (owned by `HomeView`, spanning the hero *and* the
    /// rows). The hero's Play button is marked `prefersDefaultFocus` in this
    /// scope so initial focus lands on the hero — not a Continue Watching card —
    /// without the hero having to programmatically grab (and visibly steal) it.
    var focusScope: Namespace.ID
    let onSelect: (MediaItem) -> Void
    let onPlay: (MediaItem) -> Void
    /// Fired when the hero *gains* focus (the user moved focus back up onto it),
    /// so Home can restore the full-screen hero and replay the enter transition.
    /// Not fired for interior button-to-button moves.
    var onFocusGained: () -> Void = {}
    /// Whether the hero is *receded*: the user has moved focus down onto the
    /// Continue Watching row. When true the content column (logo / metadata /
    /// action buttons / paging dots) lifts up via a transform and the full-bleed,
    /// screen-pinned backdrop translates up on its own slower track, so the
    /// Continue Watching row settles into a centered reading position — the Apple
    /// TV move. Driven by `HomeView` off the page scroll offset (the tvOS focus
    /// engine scrolls the page the instant focus lands on a lower row); the lifts
    /// here are `.offset` transforms, not layout changes, so the animation never
    /// fights the focus engine and never re-runs layout of the rows below.
    var receded: Bool = false

    /// Extra upward lift (points) applied to the hero's CONTENT column (logo,
    /// metadata, action buttons, paging dots) when the hero recedes, so the
    /// buttons/dots rise toward the top of the screen — the Apple TV look where
    /// the artwork recedes and the controls compress up high. Applied as an
    /// `.offset` transform; animates with the recede. Tunable.
    private static let recedeContentLift: CGFloat = 170
    /// Total upward travel (points) applied to the backdrop artwork when the hero
    /// recedes. The backdrop is screen-pinned (see `heroBackdrop`), so this is its
    /// absolute rise — independent of the content lift and of the page scroll. Kept
    /// LESS than the focus engine's page scroll (~480pt) so the artwork doesn't fly
    /// entirely off the top but recedes to sit just below the lifted buttons; the
    /// slow 1.6s glide (see HomeHeroBackdrop) makes it lag the scroll. Tunable.
    private static let recedeBackdropRise: CGFloat = 340

    /// The app-installed action handler — the SAME one the detail hero and the
    /// long-press context menu use — so the hero's Watchlist button is offered
    /// only when the item's provider supports it and its mutation fans out
    /// exactly like everywhere else.
    @Environment(\.mediaItemActionHandler) private var actionHandler
    @Environment(\.mediaItemActionContext) private var actionContext

    /// The index of the slide currently fronted.
    @State private var index: Int = 0
    /// Direction of the most recent page, handed to the backdrop so its parallax
    /// wipe enters from the correct edge (`true` = forward/right, `false` =
    /// backward/left). Set in `page(to:forward:)` alongside `index` so the backdrop
    /// receives the new slide id and its entering direction in the same update.
    @State private var lastPageForward: Bool = true
    /// The logical action-button selection (`0` = Play), **owned by us** rather
    /// than by the focus engine. The hero's button row is a *single* focus target
    /// (see `actionRow`), so Left/Right are resolved against this plain `@State` —
    /// never a `@FocusState` the engine mutates behind our back. Reading it inside
    /// `onMoveCommand` is therefore always the true PRE-move value, which is what
    /// makes edge detection deterministic. (The old per-button `@FocusState` +
    /// container `onMoveCommand` read the *post-move* button on device and paged
    /// the instant focus merely landed on an edge button — the bug this fixes.)
    @State private var selectedButton: Int = 0
    /// Which of the hero's two focus targets holds focus: the pill `row`, or the
    /// invisible `leftGuard` that sits just left of it. The guard exists so a Left
    /// press has an *internal* target and is captured by the hero instead of
    /// escaping to the sidebar (a lone `.focusable()` under `.focusSection()` can't
    /// trap Left when the sidebar TabView is its left neighbor — the engine jumps
    /// straight to it and `onMoveCommand` never runs). We resolve the Left against
    /// our own `selectedButton` and bounce focus straight back to the row, so the
    /// guard never visibly holds focus. Pauses auto-advance and drives the button
    /// highlight whenever it is non-`nil` (either target counts as "hero focused").
    @FocusState private var focus: HeroFocus?

    /// The hero's focus targets. `leftGuard` is an invisible 1×1 sink used purely
    /// to capture a leftward move (see `focus`).
    private enum HeroFocus: Hashable { case row, leftGuard, rightGuard }
    /// Bumped on every manual page so the auto-advance `.task` restarts its dwell
    /// from the fresh slide instead of firing early.
    @State private var advanceToken = 0
    /// Timestamp marking when the current auto-advance dwell began. Reset every
    /// time the dwell (re)starts (slide change or manual page) so the active
    /// paging dot can render a live progress fill counting down to the next page.
    /// On resume from a pause it is shifted forward by the paused duration, so the
    /// countdown continues from where it froze rather than restarting.
    @State private var dwellStart = Date()
    /// Non-`nil` while the auto-advance is paused because the user is interacting
    /// with the remote. Holds the instant the pause began so the progress gauge
    /// freezes there and the resume can compute how long it was held.
    @State private var pausedAt: Date?
    /// Bumped whenever the auto-advance pauses or resumes so the fire `.task`
    /// re-keys: a pause restarts it into its no-op (paused) branch, a resume
    /// restarts it to sleep for the remaining dwell. Slide changes / manual pages
    /// go through `advanceToken`; this is purely the pause/resume lifecycle.
    @State private var runEpoch = 0
    /// Drives the first-appearance fade-in, matching the detail hero's polish.
    @State private var heroVisible = false
    /// Optimistic watchlist state the user just toggled from the hero, keyed by
    /// ``watchlistKey(accountID:itemID:)``. Flips the button instantly on press
    /// (the loaded Watchlist row can lag, especially when adding a *series* from
    /// an episode slide) and self-heals when the real data reloads.
    @State private var watchlistOverrides: [String: Bool] = [:]
    /// Whether the fronted slide's metadata (logo / title / meta / overview /
    /// buttons) is shown. Hidden **instantly** the moment a page starts, then
    /// faded back in once the backdrop wipe has landed — so the old show's text
    /// never lingers over the new artwork.
    @State private var metadataVisible = true
    /// Bumped on every page so a late metadata fade-in from a *previous* page
    /// can't fire after a newer page has already started.
    @State private var slideToken = 0
    /// Best resolved hero backdrop URL per item id. For episode/season slides
    /// this is the **series-level** hero art (correct show, high-res — matching
    /// the detail page), resolved via ``ArtworkRouter`` and preloaded for the
    /// current slide and its neighbours so a page never animates a placeholder.
    @State private var resolvedBackdrop: [String: URL] = [:]

    /// Pending "resume auto-advance" work, scheduled after each remote input and
    /// cancelled/rescheduled by the next one, so the carousel only starts counting
    /// down again once the user has been idle for ``resumeAfterIdle`` seconds.
    @State private var resumeWork: DispatchWorkItem?
    /// How long the user must be idle after their last remote input before the
    /// auto-advance resumes counting down toward the next page.
    private static let resumeAfterIdle: Double = 2.5

    @Environment(\.colorScheme) private var colorScheme

    private var current: MediaItem? {
        guard items.indices.contains(index) else { return items.first }
        return items[index]
    }

    /// Legibility scrim tone — dark in dark mode, light in light mode (matching
    /// the detail hero).
    private var scrimTone: Color { colorScheme == .dark ? .black : .white }

    /// The action buttons the current slide offers, in visual (left-to-right)
    /// order. `.play` and `.moreInfo` are always present; `.watchlist` whenever a
    /// watchlist toggle applies to the slide's watchlist *target* (see
    /// ``watchlistTarget(for:)``) — which, for an episode/season, is its parent
    /// series, so a mid-show Continue Watching slide still gets the button.
    private func buttons(for item: MediaItem) -> [HeroButton] {
        var result: [HeroButton] = [.play, .moreInfo]
        if watchlistAction(for: item) != nil { result.append(.watchlist) }
        // A right-hand chevron on a multi-slide carousel — an affordance that
        // there's more to page through (matching the Apple TV app) and the
        // stable right-most button, so Right only pages the carousel here.
        if items.count > 1 { result.append(.next) }
        return result
    }

    /// The item the hero's Watchlist button acts on. Whole titles
    /// (movie / series / video) act on themselves; an **episode or season** acts
    /// on its parent **series** so a mid-show Continue Watching slide still offers
    /// a consistent "watchlist the show" button — episodes and seasons aren't
    /// watchlist-eligible themselves, and Plex's account watchlist only accepts
    /// whole shows anyway. Falls back to the item itself when no series id is
    /// known (an extremely rare episode with no reported series).
    ///
    /// The returned target's `isFavorite` is the authoritative watchlist state:
    /// a just-toggled optimistic override wins, else membership in the loaded
    /// Watchlist row (``watchlistedKeys``) or the item's own flag. This makes the
    /// button's fill, add/remove direction and label all reflect the real show
    /// state — an episode's own favourite flag never leaks in.
    private func watchlistTarget(for item: MediaItem) -> MediaItem {
        var target: MediaItem
        switch item.kind {
        case .episode, .season:
            guard let seriesID = item.seriesID else { return item }
            target = MediaItem(
                id: seriesID,
                title: item.parentTitle ?? item.title,
                kind: .series,
                sourceAccountID: item.sourceAccountID
            )
        default:
            target = item
        }
        let key = Self.watchlistKey(accountID: target.sourceAccountID, itemID: target.id)
        let base = watchlistedKeys.contains(key) || target.isFavorite
        target.isFavorite = watchlistOverrides[key] ?? base
        return target
    }

    /// Stable, account-scoped key for a title's watchlist membership. Account
    /// scoping avoids a Plex ratingKey on one server colliding with an unrelated
    /// title's id on another. Shared by Home when it builds ``watchlistedKeys``.
    static func watchlistKey(accountID: String?, itemID: String) -> String {
        "\(accountID ?? "-"):\(itemID)"
    }

    /// The watchlist toggle action for the slide's watchlist target, if its
    /// provider supports it.
    private func watchlistAction(for item: MediaItem) -> MediaItemAction? {
        actionHandler?.actions(for: watchlistTarget(for: item), context: actionContext)
            .first { $0 == .addToWatchlist || $0 == .removeFromWatchlist }
    }

    private static var screenHeight: CGFloat {
        #if canImport(UIKit)
        return UIScreen.main.bounds.height
        #else
        return 1080
        #endif
    }

    private static var screenWidth: CGFloat {
        #if canImport(UIKit)
        return UIScreen.main.bounds.width
        #else
        return 1920
        #endif
    }

    /// Distance the content column is lifted off the bottom edge of the
    /// full-screen hero, so the paging dots land in the lower third. Paired with
    /// `HomeView.heroRowOverlap`: the Continue Watching row is pulled up by
    /// slightly less than this, so its title peeks ~40px below the dots.
    private static let contentBottomInset: CGFloat = 252
    // Pushes the paging dots back down relative to the lifted content column.
    // (Column was lifted 120pt; this holds the dots ~60pt above their original spot.)
    private static let pagingDotsDrop: CGFloat = 60

    var body: some View {
        let height = Self.screenHeight * heroHeightFraction
        // The hero keeps its FULL layout height whether or not it is receded. An
        // earlier design collapsed this frame to lift Continue Watching into a
        // centered position — but the recede now triggers *from* the focus engine's
        // page scroll (see `HomeView`), and collapsing the frame after that scroll
        // changed the content height, shifting Continue Watching up further (jamming
        // it at the very top) and feeding back into the scroll. So we no longer
        // collapse: the page scroll alone positions Continue Watching, and the
        // recede is expressed as the content column lifting (a transform) and the
        // backdrop artwork gliding UP and out of the way behind it.
        let frameHeight = height
        // The backdrop is a full-bleed *background* of the hero content, not a
        // sibling layer in a ZStack. As a background it still bleeds edge-to-edge
        // (it ignores the horizontal safe area) but it no longer contributes to the
        // shared scroll column's width — so it can't drag the hero's own logo/
        // buttons or the rows below off the safe-area gutter (the "content sits too
        // close to the left edge once the hero mounts" bug). Its image transition is
        // still driven imperatively in UIKit (see `HomeHeroBackdrop` / `WipeImageView`)
        // rather than any SwiftUI animation, so it can never decompose into the
        // wrong-order wipe; and because we don't rely on SwiftUI insertion/removal
        // `.transition` for it, hosting it in a background is safe on tvOS. The
        // background is `.top`-aligned (horizontally centered): the content column
        // spans the symmetric safe area, so centering the full-screen-width backdrop
        // on it lands it edge-to-edge across the whole screen. Top-anchoring is what
        // makes the recede clean — see the offset notes below.
        Group {
            if let item = current {
                content(for: item)
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, minHeight: frameHeight, alignment: .bottomLeading)
        .background(alignment: .top) {
            // Laid out at the FULL hero height and anchored to the frame's TOP, so
            // it stays put as a full-bleed background regardless of the content
            // column's recede lift.
            //
            // The backdrop's OWN vertical motion — the slower `receded` rise that
            // gives the Apple TV parallax feel — is applied INSIDE HomeHeroBackdrop,
            // BEFORE its `.ignoresSafeArea`. That is the only place an offset
            // actually translates the backdrop on screen: an offset applied out here
            // (after the backdrop's safe-area breakout) is silently cancelled by the
            // breakout re-anchoring to the screen edge every layout pass — which is
            // why every earlier attempt left the artwork stuck full-screen.
            heroBackdrop(height: height)
        }
        .opacity(heroVisible ? 1 : 0)
        .onAppear {
            Task { await resolveArtwork(around: index) }
            // Start the first dwell from appearance so the initial slide's gauge
            // and auto-advance are anchored to now, not to view construction.
            restartDwell()
            guard !heroVisible else { return }
            withAnimation(.easeInOut(duration: 0.35)) { heroVisible = true }
        }
        // Re-seat the fronted slide when the curated *set* changes under us — not
        // just when it shrinks. `HomeView` seeds the hero synchronously (Continue
        // Watching + Watchlist) and then swaps in the async curated set (which
        // also includes Featured/Random); the counts often match, so keying on
        // `count` alone would leave `index` pointing at a *different* show —
        // fronted with no slide and stale art (the "wrong image / instant appear"
        // bug). Key on identity: preserve the fronted item if it survived the
        // swap, else clamp, then prune resolved art and re-resolve.
        .onChange(of: items.map(\.id)) { oldIDs, newIDs in
            guard oldIDs != newIDs else { return }
            let frontedID = oldIDs.indices.contains(index) ? oldIDs[index] : nil
            if let frontedID, let newIdx = newIDs.firstIndex(of: frontedID) {
                index = newIdx
            } else {
                index = min(index, max(0, newIDs.count - 1))
            }
            let present = Set(newIDs)
            resolvedBackdrop = resolvedBackdrop.filter { present.contains($0.key) }
            // A set swap is not a page: cancel any pending metadata fade-in and
            // show the (possibly relocated) current item. The backdrop tracks
            // `current`'s id, so if the fronted item survived the swap its art is
            // unchanged (no wipe); if it was clamped to a different item the
            // backdrop wipes to it (with whatever direction was last recorded).
            slideToken &+= 1
            metadataVisible = true
            // The set swap re-seats the fronted slide, so start a fresh dwell for
            // it (gauge from empty, no lingering pause).
            restartDwell()
            // Clamp the logical selection to the new slide's button count so it
            // can never point past the last pill after a set swap. Pure `@State`,
            // so this never touches (or drops) focus.
            if items.indices.contains(index) {
                selectedButton = min(selectedButton, max(0, buttons(for: items[index]).count - 1))
            }
            Task { await resolveArtwork(around: index) }
        }
        // Drop optimistic watchlist overrides once the authoritative loaded set
        // agrees, so a stale override can't outlive the real data.
        .onChange(of: watchlistedKeys) { _, keys in
            guard !watchlistOverrides.isEmpty else { return }
            watchlistOverrides = watchlistOverrides.filter { key, value in
                value != keys.contains(key)
            }
        }
        // Auto-advance: the fire is rescheduled whenever `autoAdvanceKey` changes
        // (slide change, manual page, pause/resume, or the item count settling).
        // It runs REGARDLESS of focus — focus lands on the hero action row by
        // default, so gating on `focus == nil` froze the carousel the entire time
        // the user was looking at it. Instead, real remote input pauses it (see
        // `noteInteraction`), so it never pages out from under an interacting user.
        .task(id: autoAdvanceKey) {
            guard settings.autoAdvance, items.count > 1 else { return }
            // Paused (user is interacting): schedule no fire at all. The gauge is
            // frozen at `pausedAt`; resuming bumps `runEpoch` to reschedule here.
            guard pausedAt == nil else { return }
            // Fire after the *remaining* dwell so that resuming after a pause
            // finishes the countdown from where it froze instead of restarting it.
            let duration = Double(settings.autoAdvanceSeconds)
            let remaining = max(0, duration - Date().timeIntervalSince(dwellStart))
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            guard !Task.isCancelled else { return }
            page(to: (index + 1) % items.count, keepButton: selectedButton, forward: true)
        }
    }

    /// The Home hero backdrop. Renders the fronted slide's art in a UIKit
    /// two-layer view that performs the Apple TV **parallax wipe imperatively** via
    /// Core Animation (see `HomeHeroBackdrop` / `WipeImageView`) — never a SwiftUI
    /// animation, so it cannot decompose into the intermittent wrong-order wipe.
    /// Changing `current`'s id (which happens when `index` changes on a page) is
    /// what triggers a transition; `lastPageForward` gives it the entering edge.
    /// The scrim, bottom dissolve, overscan breakout and scroll parallax are static
    /// SwiftUI treatment layered over the image and never animate.
    @ViewBuilder
    private func heroBackdrop(height: CGFloat) -> some View {
        let w = Self.screenWidth
        if let item = current {
            HomeHeroBackdrop(
                urls: primaryBackdropURLs(for: item),
                asyncFallbackURL: backdropFallback(for: item),
                slideID: item.id,
                forward: lastPageForward,
                width: w,
                height: height,
                scrimTone: scrimTone,
                // Full-screen hero: keep the artwork opaque far lower than the
                // detail page (0.33) and only feather the very bottom into the
                // Continue Watching panel.
                dissolveStart: 0.82,
                // The recede rise. The backdrop is screen-pinned by its own
                // `.ignoresSafeArea(.top)` breakout (it does NOT scroll with the
                // page), so it needs no scroll counter. Drive it purely off
                // `receded`: 0 at rest, a clean rise when receded, animated slowly
                // (1.6s) inside HomeHeroBackdrop so it keeps gliding up after the
                // content lift settles (the Apple TV feel).
                recedeLift: receded ? Self.recedeBackdropRise : 0
            )
        } else {
            Color.clear.frame(width: w, height: height)
        }
    }

    /// The dwell key: any change restarts the auto-advance fire `.task`. Slide
    /// index and a manual page bump (`advanceToken`) start a fresh dwell; the
    /// pause/resume lifecycle (`runEpoch`) restarts it into its paused no-op or to
    /// sleep the remaining time; `slideToken` covers set-swaps / the seed→curated
    /// grow (it is bumped whenever the fronted slide is re-seated) so the fire and
    /// the gauge stay in sync. Focus is deliberately NOT part of this — the
    /// carousel cycles whether or not the hero holds focus; only real remote input
    /// pauses it.
    private var autoAdvanceKey: String {
        "\(index)-\(advanceToken)-\(runEpoch)-\(slideToken)"
    }

    // MARK: - Content column

    /// Scroll anchor just above the action row. Pressing **down** off the hero
    /// scrolls this near the top of the viewport, so the show's logo/title lift
    /// off the top and the overview/buttons/dots settle into the upper region
    /// with the Continue Watching row centered below — the Apple TV "recede".
    static let recedeAnchorID = "home-hero-recede"

    /// Constant identity for the single focusable action row. Never changes — so
    /// focus is retained across a page (item id changes).
    static let actionRowFocusID = "home-hero-action-row"

    @ViewBuilder
    private func content(for item: MediaItem) -> some View {
        let hideText = spoilerSettings.shouldHideText(for: item)
        VStack(alignment: .leading, spacing: 12) {
            // The show *description* (logo/title/metadata/overview). ONLY this
            // fades: hidden instantly on a page and faded back in once the new
            // backdrop has wiped into place, so the old title/overview never sit
            // over the incoming artwork. The action row is deliberately NOT inside
            // this fade — a focusable view at opacity 0 is un-focusable on tvOS, so
            // fading the buttons dropped focus mid-page and the ScrollView scrolled
            // down to the next focusable (a Continue Watching card). Keeping the
            // buttons opaque and focusable throughout the transition pins focus and
            // the scroll in place.
            VStack(alignment: .leading, spacing: 12) {
                HeroLogoArtwork(
                    primaryURL: item.logoURL,
                    asyncFallbackURL: logoFallback(for: item),
                    backgroundSample: backgroundSample(for: item)
                ) {
                    Text(hideText ? spoilerSettings.maskedTitle(for: item) : item.title)
                        .font(.system(size: 64, weight: .bold))
                        .lineLimit(2)
                        .minimumScaleFactor(0.5)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: 1200, alignment: .leading)
                        .contentTransition(.opacity)
                }
                .id("logo-\(item.id)")

                metadataLine(for: item)

                if !hideText, let overview = item.overview {
                    Text(overview)
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                        .lineSpacing(2)
                        .lineLimit(3, reservesSpace: true)
                        .frame(maxWidth: 960, alignment: .topLeading)
                        .contentTransition(.opacity)
                }
            }
            .opacity(metadataVisible ? 1 : 0)
            // Snap the metadata *hide* instantly (so the outgoing text vanishes as
            // the wipe starts instead of fading out over the incoming art) while
            // still allowing the delayed fade-IN once the wipe has landed.
            .transaction { if !metadataVisible { $0.animation = nil } }

            // Zero-height recede target: sits just above the buttons so a
            // down-press lifts the logo/title off the top of the screen.
            Color.clear
                .frame(height: 0)
                .id(Self.recedeAnchorID)

            // The pills fade with the metadata (see `actionRow`), but their focus
            // target is an always-opaque overlay — so a page never drops focus or
            // shifts the scroll even as the buttons disappear and reappear.
            actionRow(for: item)

            pagingDots
                // Center the page indicators across the full hero width (leading
                // and trailing padding are equal, so this is true screen-center)
                // while the logo / metadata / buttons stay left-aligned. Kept
                // visible through the wipe so paging stays legible.
                .frame(maxWidth: .infinity, alignment: .center)
                // The whole column was lifted 120pt (contentBottomInset 132→252) to
                // raise the logo / metadata / buttons. The dots should stay at their
                // original screen position, so push them back down by the same 120pt.
                .offset(y: Self.pagingDotsDrop)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, PlozzTheme.Metrics.screenPadding)
        .padding(.trailing, PlozzTheme.Metrics.screenPadding)
        .padding(.leading, PlozzTheme.Metrics.heroLeadingPadding)
        // Lift the content column off the very bottom of the full-screen hero so
        // the logo / metadata / buttons / dots sit near the lower third and the
        // Continue Watching row can peek in just beneath the dots. This inset is
        // STATIC so it never re-runs layout during the recede.
        .padding(.bottom, Self.contentBottomInset)
        // When receded, lift the whole column further toward the top (buttons/dots
        // stay visible but move up). Expressed as an `.offset` — a post-layout GPU
        // transform — NOT padding, so the recede animation never triggers a relayout
        // of this column or the rows below it. Padding-based lifts on a non-lazy
        // stack re-run full layout every animation frame, which is what made the
        // slow recede stutter; a transform is free at any duration.
        .offset(y: receded ? -Self.recedeContentLift : 0)
    }

    @ViewBuilder
    private func metadataLine(for item: MediaItem) -> some View {
        let metadata = item.metadataComponents()
        let badge = item.ratingBadge
        if badge != nil || !metadata.isEmpty {
            HStack(alignment: .center, spacing: 16) {
                if let badge {
                    MediaBadgeChip(badge: badge)
                }
                if !metadata.isEmpty {
                    Text(metadata.joined(separator: "  ·  "))
                        .font(.system(size: 23, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                }
            }
        }
    }

    // MARK: - Action row + focus/paging

    @ViewBuilder
    private func actionRow(for item: MediaItem) -> some View {
        let itemButtons = buttons(for: item)
        // Named VoiceOver actions for *every* visible pill (the row is a single
        // a11y element, so without these only the highlighted action would be
        // reachable). Order matches the visible pills.
        let a11yActions: [(String, () -> Void)] = itemButtons.map { button in
            switch button {
            case .play: return (item.resumePosition != nil ? "Resume" : "Play", { onPlay(item) })
            case .moreInfo: return ("More Info", { onSelect(item) })
            case .watchlist:
                let fav = watchlistTarget(for: item).isFavorite
                return (fav ? "Remove from Watchlist" : "Add to Watchlist", { performWatchlist(for: item) })
            case .next: return ("Next", { advanceForward() })
            }
        }
        // spacing: 0 so the 1pt invisible focus guard below adds no gap ahead of the
        // pills — otherwise the guard + gap pushed the whole button row right of the
        // logo/metadata. The pills keep their own 24pt spacing in the inner HStack.
        HStack(spacing: 0) {
            // Invisible focus guard, just left of the pills and inside the same
            // focus section. It gives the focus engine an *internal* leftward
            // target so a Left press is captured by the hero (routed through
            // `.onChange(of: focus)` below) instead of escaping to the sidebar —
            // which a lone focusable can't prevent. It steps aside (non-focusable)
            // only at the one escape spot (first item, left-most button, sidebar
            // nav) *while focus is resting on the row*, so Left there falls through
            // and opens the side navigation, exactly as on the Apple TV app.
            //
            // Crucially the inactivation is gated on `focus == .row`, NOT on
            // `allowsSidebarEscape` alone: `handleLeft()` moves `selectedButton`
            // to 0 (or pages back to item 0) which flips `allowsSidebarEscape` to
            // true in the very transaction that is bouncing focus guard→row. If the
            // guard's focusability keyed on that flip alone, it would go
            // non-focusable *while still holding focus*, and the focus engine could
            // relocate to a Continue Watching card (scroll-down regression) or
            // strand focus. Requiring `focus == .row` means the guard can only lose
            // focusability once focus has already left it for the row — no race.
            Color.clear
                .frame(width: 1, height: 1)
                .focusable(leftGuardActive)
                .focused($focus, equals: .leftGuard)
                .accessibilityHidden(true)

            // The VISIBLE pills. Non-focusable and free to fade with the rest of
            // the metadata on a page — exactly like the Apple TV hero, where the
            // buttons vanish on press and reappear on landing. Focus is NOT here
            // (see the overlay), so fading these to opacity 0 can't drop focus or
            // shift the scroll. `.opacity` keeps their layout, so the focus overlay
            // below keeps a stable frame throughout the fade.
            HStack(spacing: 24) {
                ForEach(Array(itemButtons.enumerated()), id: \.element) { offset, button in
                    heroButtonVisual(button, for: item, selected: focus != nil && selectedButton == offset)
                }
            }
            .opacity(metadataVisible ? 1 : 0)
            // Snap the pills' hide instantly (matches the metadata above); the
            // delayed fade-IN still animates.
            .transaction { if !metadataVisible { $0.animation = nil } }
            .allowsHitTesting(false)
            // ── The single hero focus target: an always-opaque, invisible focusable
            // leaf layered *over* the pills. Because `.overlay` is applied after the
            // pills' `.opacity`, it stays fully opaque and focusable even while the
            // pills fade to 0 — so focus (and therefore the scroll position) is
            // pinned throughout a page, while the buttons still disappear and
            // reappear. There is NO per-button `@FocusState`: Left and Right are
            // each captured by an invisible guard (see above / below) and resolved
            // in `.onChange(of: focus)` against our own `selectedButton` (always the
            // true pre-move value); Down is left to the enclosing section's
            // `onMoveCommand`. The hero pages only on a real edge press, never
            // because focus merely *landed* on an edge button.
            //
            // Select is `.onTapGesture` (the select-press fires the tap) — the SAME
            // pattern the Continue Watching cards use (`focusableCard`), NOT a
            // `Button` (a `Button` paints tvOS's white focus platter over the
            // backdrop, which `.focusEffectDisabled()` can't fully remove). Crucially
            // `.onMoveCommand` is NOT attached here: on tvOS a move-command handler on
            // the same view as `.onTapGesture` intercepts the select press, so the
            // tap only landed intermittently (Select "needed five presses"). Moving
            // the move handling up to the `.focusSection()` container (Apple's
            // recommended placement) leaves this leaf a clean tap target. ──
            .overlay {
                Color.clear
                    .contentShape(Rectangle())
                    .focusable(true)
                    .focused($focus, equals: .row)
                    // Initial Home focus lands on the hero (not a CW card).
                    .prefersDefaultFocus(true, in: focusScope)
                    // No system focus platter on the clear overlay — we draw our own
                    // selection styling via `selectedButton`.
                    .focusEffectDisabled()
                    // Remote **Select** activates the selected pill. Stands alone
                    // (no `.onMoveCommand` here) so the tap can't be intercepted.
                    .onTapGesture { activateSelected() }
                    // Play/Pause is a shortcut straight to playback.
                    .onPlayPauseCommand { noteInteraction(); if let item = current { onPlay(item) } }
                    .accessibilityElement(children: .ignore)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel(accessibilityLabel(for: item))
                    .accessibilityAction { activateSelected() }
                    .modifier(HeroActionAccessibility(actions: a11yActions))
            }
            // Pin a *constant* identity so focus is retained across a page (item
            // id changes). Never key this on the item id — that would drop focus.
            .id(Self.actionRowFocusID)

            // Invisible focus guard, just right of the pills and inside the same
            // focus section — the mirror image of the left guard. A Right press
            // has no focusable neighbour to relocate to (the pills are a single
            // leaf, and everything else is below), so on tvOS a container-level
            // `.onMoveCommand` never fires for it: Right silently died. Giving the
            // engine an *internal* rightward target means a Right press is captured
            // by the hero (routed through `.onChange(of: focus)` → `handleRight()`)
            // exactly the way Left is captured by the left guard, with no reliance
            // on `onMoveCommand`. Unlike the left guard it is ALWAYS focusable:
            // Right never escapes the hero (there is nothing to the right to escape
            // to) — it always pages or moves the selection — so there is no
            // step-aside case and no `allowsSidebarEscape`-style race to guard.
            Color.clear
                .frame(width: 1, height: 1)
                .focusable(true)
                .focused($focus, equals: .rightGuard)
                .accessibilityHidden(true)
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Always-on (never toggled): a lone focusable under a *conditional* focus
        // section churned structure on every interior move on the first slide,
        // which jostled the scroll position. Constant confinement keeps Down going
        // to Continue Watching and Right paging cleanly.
        .focusSection()
        // Move handling lives HERE, on the section container, not on the focus
        // target leaf. Apple's guidance is to put `.onMoveCommand` on a container
        // rather than the focused element, and doing so is what lets the leaf's
        // `.onTapGesture` (Select) fire reliably — a move handler on the same view
        // was intercepting the select press. Its ONLY job now is to pause the
        // auto-advance on any directional input (see `handleMove`): all
        // paging/interior behaviour is driven by the invisible Left/Right guards,
        // Up is left to the system, and the Down-recede is driven by the page
        // scroll in `HomeView` — not by this handler.
        .onMoveCommand { _ in handleMove() }
        .onChange(of: focus) { old, new in
            switch new {
            case .leftGuard:
                // The engine parked focus on the guard because Left was pressed.
                // Resolve it and bounce straight back to the row.
                handleLeft()
            case .rightGuard:
                // The engine parked focus on the guard because Right was pressed.
                // Resolve it and bounce straight back to the row (mirror of Left).
                handleRight()
            case .row:
                // Focus arriving into the hero from *outside* (a row below / the
                // tab bar): snap back to full-screen and scroll the page to the top.
                // We do NOT act on focus *loss* — focus can drop transiently, and
                // the recede is driven by the page scroll (see `HomeView`), not here.
                if old == nil {
                    if let item = current {
                        selectedButton = min(selectedButton, max(0, buttons(for: item).count - 1))
                    }
                    onFocusGained()
                }
            case .none:
                // Focus left the hero entirely (down to a row, up to the tab bar, or
                // left to the sidebar). Nothing to do: the recede is driven purely
                // by the page scroll offset in `HomeView`.
                break
            }
        }
    }

    /// Whether Left on the left-most button of the *current* slide should open
    /// the side navigation instead of paging — the one case the reducer resolves
    /// to `.escape`. Mirrors `HeroCarouselFocus`, and controls whether the left
    /// focus guard steps aside so Left can reach the sidebar.
    private var allowsSidebarEscape: Bool {
        HeroCarouselFocus.resolve(
            direction: .left,
            itemIndex: index,
            itemCount: items.count,
            focusedButton: selectedButton,
            buttonCount: max(1, current.map { buttons(for: $0).count } ?? 1),
            navigationStyle: navigationStyle
        ) == .escape
    }

    /// Whether the invisible left guard should be focusable. It captures a Left
    /// press so the hero handles it internally instead of the engine escaping to
    /// the sidebar. It steps aside (non-focusable) *only* at the escape spot AND
    /// while focus is resting on the row — never while the guard itself holds
    /// focus. Gating on `focus == .row` is what makes the guard→row bounce
    /// race-free: `handleLeft()` moves `selectedButton`/`index` (flipping
    /// `allowsSidebarEscape` to true) in the same transaction that re-pins focus to
    /// `.row`; if focusability keyed on `allowsSidebarEscape` alone, the guard would
    /// go non-focusable *while focused*, and the engine could relocate focus to a
    /// Continue Watching card (scroll-down) or strand it. Requiring `focus == .row`
    /// means the guard can only lose focusability once focus has already moved off
    /// it, so the escape only fires from a genuine at-rest Left on item 0's
    /// left-most button.
    private var leftGuardActive: Bool {
        !(allowsSidebarEscape && focus == .row)
    }

    /// The container-level move handler. Its ONLY job is to pause the auto-advance
    /// on any directional input so the carousel can't page out from under the user.
    /// It does NOT resolve paging for any direction: **Left and Right are each
    /// captured by their invisible focus guard** (→ `handleLeft()` / `handleRight()`),
    /// Up is left to the system, and the Down-recede is driven by the page scroll in
    /// `HomeView`. It only observes (never consumes) the move, so edge Left/Right
    /// presses still page normally.
    private func handleMove() {
        noteInteraction()
    }

    /// Resolves a Left press captured by the invisible left guard, then bounces
    /// focus straight back to the pill row so the guard never visibly holds it.
    /// Interior moves adjust `selectedButton`; `.advance` pages backward. The one
    /// `.escape` case (first item, left-most button, sidebar) can't reach here —
    /// the guard is non-focusable there, so Left falls through to the sidebar.
    private func handleLeft() {
        noteInteraction()
        defer { focus = .row }
        guard let item = current else { return }
        let buttonCount = buttons(for: item).count
        selectedButton = min(selectedButton, max(0, buttonCount - 1))
        let outcome = HeroCarouselFocus.resolve(
            direction: .left,
            itemIndex: index,
            itemCount: items.count,
            focusedButton: selectedButton,
            buttonCount: buttonCount,
            navigationStyle: navigationStyle
        )
        switch outcome {
        case let .moveButton(newIndex):
            selectedButton = newIndex
        case let .advance(toItem, keepButton):
            page(to: toItem, keepButton: keepButton, forward: false)
        case .escape, .blocked:
            break
        }
    }

    /// Resolves a Right press captured by the invisible right guard, then bounces
    /// focus straight back to the pill row so the guard never visibly holds it —
    /// the exact mirror of `handleLeft()`. Interior moves adjust `selectedButton`;
    /// `.advance` pages forward. Right never escapes (the reducer never returns
    /// `.escape` for a rightward move), so there is no fall-through case. Routing
    /// Right through the guard (rather than `onMoveCommand`) is what makes it fire
    /// reliably even at the row's right edge, where there is no neighbour for a
    /// container move handler to relocate to.
    private func handleRight() {
        noteInteraction()
        defer { focus = .row }
        guard let item = current else { return }
        let buttonCount = buttons(for: item).count
        selectedButton = min(selectedButton, max(0, buttonCount - 1))
        let outcome = HeroCarouselFocus.resolve(
            direction: .right,
            itemIndex: index,
            itemCount: items.count,
            focusedButton: selectedButton,
            buttonCount: buttonCount,
            navigationStyle: navigationStyle
        )
        switch outcome {
        case let .moveButton(newIndex):
            selectedButton = newIndex
        case let .advance(toItem, keepButton):
            page(to: toItem, keepButton: keepButton, forward: true)
        case .escape, .blocked:
            break
        }
    }

    /// Fires the currently-selected pill's action (remote Select / Play-Pause).
    /// Resolves the live slide and clamps the index defensively so a stale
    /// selection can never dispatch the wrong (or an out-of-range) action.
    private func activateSelected() {
        noteInteraction()
        guard let item = current else { return }
        let itemButtons = buttons(for: item)
        let idx = min(selectedButton, max(0, itemButtons.count - 1))
        guard itemButtons.indices.contains(idx) else { return }
        switch itemButtons[idx] {
        case .play: onPlay(item)
        case .moreInfo: onSelect(item)
        case .watchlist: performWatchlist(for: item)
        case .next: advanceForward()
        }
    }

    /// Toggles the watchlist state for `item`, flipping the pill instantly.
    private func performWatchlist(for item: MediaItem) {
        guard let action = watchlistAction(for: item) else { return }
        let target = watchlistTarget(for: item)
        actionHandler?.perform(action, on: target, context: actionContext)
        // Flip the button instantly; the loaded row can lag (an added series from
        // an episode slide isn't an existing card).
        let key = Self.watchlistKey(accountID: target.sourceAccountID, itemID: target.id)
        watchlistOverrides[key] = (action == .addToWatchlist)
    }

    /// VoiceOver label for the row's currently-selected action.
    private func accessibilityLabel(for item: MediaItem) -> String {
        let itemButtons = buttons(for: item)
        guard itemButtons.indices.contains(selectedButton) else { return item.title }
        let name: String
        switch itemButtons[selectedButton] {
        case .play: name = item.resumePosition != nil ? "Resume" : "Play"
        case .moreInfo: name = "More Info"
        case .watchlist: name = watchlistTarget(for: item).isFavorite ? "Remove from Watchlist" : "Add to Watchlist"
        case .next: name = "Next"
        }
        return "\(item.title), \(name)"
    }

    /// Adds a named VoiceOver action per visible pill so every hero action stays
    /// reachable even though the row is a single accessibility element.
    private struct HeroActionAccessibility: ViewModifier {
        let actions: [(String, () -> Void)]
        func body(content: Content) -> some View {
            actions.reduce(AnyView(content)) { view, entry in
                AnyView(view.accessibilityAction(named: Text(entry.0), entry.1))
            }
        }
    }

    /// One hero action rendered as a **non-focusable** glass pill. Selection is
    /// ours (`selected`), not the focus engine's — the whole row is a single focus
    /// target — so the bright "focused" treatment rides `selectedButton` with no
    /// focus-engine round trip. Mirrors the detail hero's Liquid Glass look: a
    /// translucent glass pill normally; the bright white fill + dark glyph + lift
    /// when it's the selected pill and the hero holds focus.
    @ViewBuilder
    private func heroButtonVisual(_ button: HeroButton, for item: MediaItem, selected: Bool) -> some View {
        switch button {
        case .play:
            heroPill(selected: selected, prominent: true) {
                Label(item.resumePosition != nil ? "Resume" : "Play", systemImage: "play.fill")
                    .font(.system(size: 28, weight: .semibold))
            }
        case .moreInfo:
            heroPill(selected: selected, prominent: false) {
                Label("More Info", systemImage: "info.circle")
                    .font(.system(size: 28, weight: .semibold))
            }
        case .watchlist:
            let target = watchlistTarget(for: item)
            heroPill(selected: selected, prominent: false) {
                Image(systemName: target.isFavorite ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 28, weight: .semibold))
                    .symbolEffect(.bounce, value: target.isFavorite)
                    .frame(width: 34, height: 34)
            }
        case .next:
            heroPill(selected: selected, prominent: false) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 28, weight: .semibold))
                    .frame(width: 34, height: 34)
            }
        }
    }

    /// The glass-pill chrome shared by every hero action. Identity-stable (only
    /// animatable properties vary with `selected`), so nothing here can disturb
    /// focus. `prominent` tints the idle Play pill with the app accent, matching
    /// `.glassProminent` on the detail hero. Colour/fill snap instantly (no comet
    /// trail); only the scale/shadow lift animates as selection moves.
    @ViewBuilder
    private func heroPill<Content: View>(
        selected: Bool,
        prominent: Bool,
        @ViewBuilder _ label: () -> Content
    ) -> some View {
        let shape = Capsule(style: .continuous)
        label()
            .foregroundStyle(selected ? Color.black : Color.white)
            .transaction { $0.animation = nil }
            .padding(.horizontal, 30)
            .padding(.vertical, 18)
            .background {
                ZStack {
                    heroPillIdleBackground(shape: shape, prominent: prominent)
                        .opacity(selected ? 0 : 1)
                    shape.fill(.white).opacity(selected ? 1 : 0)
                }
                .transaction { $0.animation = nil }
            }
            .clipShape(shape)
            .scaleEffect(selected ? 1.06 : 1.0)
            .shadow(color: .black.opacity(selected ? 0.30 : 0), radius: selected ? 14 : 0, y: selected ? 8 : 0)
            .animation(.easeOut(duration: 0.16), value: selected)
    }

    @ViewBuilder
    private func heroPillIdleBackground(shape: Capsule, prominent: Bool) -> some View {
        if #available(tvOS 26.0, *) {
            // Liquid Glass for every idle pill. The prominent Play/Resume pill was
            // previously a solid `Color.accentColor` fill, but the app ships an
            // EMPTY `AccentColor` asset, so inside this package `Color.accentColor`
            // resolves to white — a white pill with an invisible white label. Use
            // regular glass and give the prominent pill a slightly brighter white
            // tint so it reads as "primary" while its white label stays legible.
            shape.fill(.clear)
                .glassEffect(prominent ? .regular.tint(.white.opacity(0.18)) : .regular, in: shape)
        } else {
            shape.fill(.ultraThinMaterial)
        }
    }

    /// Fronts `toItem` and restarts the auto-advance dwell. Callers only ever page
    /// by ±1 (Right/Left/chevron/auto-advance). This is now purely a *state* change:
    /// updating `index` swaps the fronted slide's id / candidate URLs, and the
    /// backdrop's UIKit parallax wipe (`HomeHeroBackdrop`) picks that up and pushes
    /// to the new art on its own. There is no SwiftUI backdrop animation here at all
    /// — that is the whole point of the redesign. `isForward` is recorded into
    /// `lastPageForward` so the wipe enters from the correct edge.
    private func page(to toItem: Int, keepButton: Int, forward isForward: Bool) {
        guard items.indices.contains(toItem), toItem != index else { return }
        // Record the entering direction so the backdrop wipe pushes from the
        // correct edge. Batched with `index` below into one SwiftUI update.
        lastPageForward = isForward

        // Restart the metadata fade cycle: hide the outgoing show's text instantly,
        // fade the new show's text back in once the wipe has landed.
        beginTransition()

        index = toItem
        advanceToken &+= 1
        // A page is a fresh dwell: reset the progress gauge (so the newly-active
        // dot opens from empty instead of flashing the outgoing dot's progress)
        // and clear any pause so the new slide counts down normally.
        restartDwell()
        metadataVisible = false
        selectedButton = min(keepButton, max(0, buttons(for: items[toItem]).count - 1))

        Task { await resolveArtwork(around: toItem) }
    }

    /// Begins a fresh auto-advance dwell from now: the progress gauge fills from
    /// empty and any interaction pause is cleared. Called on a page, on first
    /// appearance, and when the curated set re-seats the fronted slide.
    private func restartDwell() {
        dwellStart = .now
        pausedAt = nil
        resumeWork?.cancel()
        resumeWork = nil
    }

    /// Records a remote interaction: freezes the auto-advance so it can't page out
    /// from under the user mid-navigation, and (re)arms the idle timer that will
    /// resume the countdown once they stop. Purely a side effect — it never
    /// consumes the input, so edge Left/Right presses still page as normal.
    private func noteInteraction() {
        guard settings.autoAdvance, items.count > 1 else { return }
        if pausedAt == nil {
            // Freeze the gauge at this instant and cancel the pending auto-page.
            pausedAt = Date()
            runEpoch &+= 1
        }
        scheduleResume()
    }

    /// (Re)schedules the resume so it fires only after ``resumeAfterIdle`` seconds
    /// with no further input. Each interaction cancels the previous one.
    private func scheduleResume() {
        resumeWork?.cancel()
        let work = DispatchWorkItem { resumeAutoAdvance() }
        resumeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.resumeAfterIdle, execute: work)
    }

    /// Resumes a paused auto-advance: shifts `dwellStart` forward by however long
    /// the pause was held so the gauge continues from where it froze, then re-keys
    /// the fire `.task` to sleep the remaining time.
    private func resumeAutoAdvance() {
        guard let pausedAt else { return }
        dwellStart = dwellStart.addingTimeInterval(Date().timeIntervalSince(pausedAt))
        self.pausedAt = nil
        resumeWork = nil
        runEpoch &+= 1
    }

    /// Pages one slide forward (wrapping), keeping focus on the destination's
    /// chevron so repeated chevron presses / right-edge presses walk through the
    /// carousel. Used by the chevron button and the auto-advance timer.
    private func advanceForward() {
        guard items.count > 1 else { return }
        let next = (index + 1) % items.count
        let destinationButtons = buttons(for: items[next]).count
        page(to: next, keepButton: destinationButtons - 1, forward: true)
    }

    /// Schedules the fronted show's metadata (logo/title/meta/overview/buttons) to
    /// fade back in after a page. The text is hidden **instantly** when the page
    /// starts (see `content(for:)`/`actionRow(for:)`) so the outgoing show's text
    /// never lingers over the incoming art. All of it (metadata, overview, and the
    /// action buttons) shares the single `metadataVisible` flag, so it fades in
    /// together, part-way through the backdrop wipe rather than waiting for it to
    /// fully land. Guarded by ``slideToken`` so a rapid second page cancels the
    /// first page's pending fade-in.
    private func beginTransition() {
        slideToken &+= 1
        let token = slideToken
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 280_000_000)
            guard slideToken == token else { return }
            withAnimation(.easeInOut(duration: 0.3)) { metadataVisible = true }
        }
    }

    // MARK: - Paging dots

    @ViewBuilder
    private var pagingDots: some View {
        if items.count > 1 {
            HStack(spacing: Self.dotSpacing) {
                ForEach(items.indices, id: \.self) { i in
                    pagingIndicator(active: i == index)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            // Liquid Glass rounded container so the indicators stay legible over
            // any backdrop (matches the hero action pills' glass treatment).
            .background { pagingDotsGlass(shape: Capsule()) }
            .padding(.top, 10)
            .accessibilityHidden(true)
        }
    }

    private static let dotSize: CGFloat = 8
    private static let dotSpacing: CGFloat = 8
    private static let activeDotWidth: CGFloat = 30
    /// Duration of the simultaneous dot→pill / pill→dot open/close on a page.
    private static let dotMorph: Double = 0.3

    /// A single page indicator. It is always the same `Capsule` so its width can
    /// smoothly animate between a dot (inactive) and a pill (active) — the active
    /// one opening exactly as the outgoing one closes, keeping the container width
    /// constant. The active pill fills left→right as the auto-advance dwell elapses
    /// (a live "time until next page" gauge).
    private func pagingIndicator(active: Bool) -> some View {
        Capsule()
            .fill(Color.white.opacity(0.28))
            .overlay(alignment: .leading) {
                activeDotFill(active: active, trackWidth: Self.activeDotWidth, height: Self.dotSize)
            }
            .frame(width: active ? Self.activeDotWidth : Self.dotSize, height: Self.dotSize)
            .clipShape(Capsule())
            .animation(.easeInOut(duration: Self.dotMorph), value: active)
    }

    /// The bright progress fill inside an indicator. Kept in a `TimelineView` for
    /// every dot (stable identity) so the active one grows from a dot to the full
    /// pill across the dwell; when a dot goes inactive its fill closes back down
    /// (animated by the `active` flip), and when auto-advance is off the active
    /// pill just sits fully lit.
    private func activeDotFill(active: Bool, trackWidth: CGFloat, height: CGFloat) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !settings.autoAdvance || pausedAt != nil)) { timeline in
            Capsule()
                .fill(Color.white)
                .frame(
                    width: brightFillWidth(active: active, trackWidth: trackWidth, height: height, now: timeline.date),
                    height: height
                )
                // Animate only the open/close that a page (active flip) triggers;
                // the per-frame progress growth is driven by the timeline itself.
                .animation(.easeInOut(duration: Self.dotMorph), value: active)
        }
    }

    /// Width of an indicator's bright fill: `0` when inactive, the full pill when
    /// auto-advance is off, otherwise a dot growing to the full pill across the
    /// dwell. Interpolating from `height` (a dot) up to `trackWidth` — rather than
    /// `max(height, trackWidth * progress)` — means the fill starts moving the
    /// instant the dwell begins instead of sitting pinned at a dot until progress
    /// passes `height / trackWidth`. While paused it freezes at `pausedAt`.
    private func brightFillWidth(active: Bool, trackWidth: CGFloat, height: CGFloat, now: Date) -> CGFloat {
        guard active else { return 0 }
        guard settings.autoAdvance else { return trackWidth }
        let duration = max(1, Double(settings.autoAdvanceSeconds))
        let reference = pausedAt ?? now
        let progress = min(1, max(0, reference.timeIntervalSince(dwellStart) / duration))
        return height + (trackWidth - height) * progress
    }

    /// Liquid Glass background for the paging-dot container: real glass on
    /// tvOS 26+, `.ultraThinMaterial` below (mirrors `heroPillIdleBackground`).
    @ViewBuilder
    private func pagingDotsGlass(shape: Capsule) -> some View {
        if #available(tvOS 26.0, *) {
            shape.fill(.clear).glassEffect(.regular, in: shape)
        } else {
            shape.fill(.ultraThinMaterial)
        }
    }

    // MARK: - Backdrop

    /// The ordered primary backdrop URLs for a slide — mirroring `DetailHeroView`:
    /// the **server's own hero/backdrop art first** (for a Jellyfin episode the
    /// series backdrop rides on `fallbackArtworkURL`; for Plex it's already in
    /// `heroBackdropURL`), then the router-resolved art. The router is only a
    /// *fallback* here (via `backdropFallback`), never the primary — resolving it
    /// first is what made episode slides show a different, low-res image than the
    /// detail page. Any resolved art is prepended (it's the server art for whole
    /// titles, or the router hero only when the server gave none).
    private func primaryBackdropURLs(for item: MediaItem) -> [URL] {
        var urls: [URL] = []
        if let resolved = resolvedBackdrop[item.id] { urls.append(resolved) }
        urls.append(contentsOf: [
            item.heroBackdropURL,
            item.backdropURL,
            item.fallbackArtworkURL
        ].compactMap { $0 })
        var seen = Set<URL>()
        return urls.filter { seen.insert($0).inserted }
    }

    // MARK: - Artwork routing / preload

    /// Resolves + preloads the best hero art for the slide at `idx` and its
    /// immediate neighbours, so paging never animates a placeholder and every
    /// slide shows correct, high-res art.
    private func resolveArtwork(around idx: Int) async {
        let count = items.count
        guard count > 0 else { return }
        let targets = [idx, (idx + 1) % count, (idx - 1 + count) % count]
        for i in targets where items.indices.contains(i) {
            await resolveArtwork(for: items[i])
        }
    }

    /// Resolves the best hero backdrop URL for one item and warms the decoded
    /// image cache. Mirrors `DetailHeroView`: prefer the **server's** hero art
    /// (for an episode/season, the series backdrop carried on `fallbackArtworkURL`
    /// — the same art the detail page shows), and only reach for the router when
    /// the server provided none. Resolving the router *first* for episodes was the
    /// "wrong / low-res image" bug.
    @MainActor
    private func resolveArtwork(for item: MediaItem) async {
        guard resolvedBackdrop[item.id] == nil else { return }
        var best: URL? = item.heroBackdropURL ?? item.backdropURL ?? item.fallbackArtworkURL
        switch item.kind {
        case .folder, .collection, .unknown:
            break // server art only; no external router for containers
        default:
            if best == nil {
                best = await ArtworkRouter.shared.artworkURL(.hero, for: item)
            }
        }
        guard let url = best else { return }
        resolvedBackdrop[item.id] = url
        #if canImport(UIKit)
        ArtworkImageCache.shared.prefetch(url)
        #endif
    }

    // MARK: - External-art fallbacks (mirror DetailHeroView)

    private func backdropFallback(for item: MediaItem) -> (@Sendable () async -> URL?)? {
        switch item.kind {
        case .folder, .collection, .unknown: return nil
        default: break
        }
        return { await ArtworkRouter.shared.artworkURL(.hero, for: item) }
    }

    private func logoFallback(for item: MediaItem) -> (@Sendable () async -> URL?)? {
        switch item.kind {
        case .folder, .collection, .unknown: return nil
        default: break
        }
        return { await ArtworkRouter.shared.artworkURL(.logo, for: item) }
    }

    private func backgroundSample(for item: MediaItem) -> (@Sendable () async -> HeroBackgroundSample?)? {
        #if canImport(UIKit)
        let urls = [item.heroBackdropURL, item.backdropURL].compactMap { $0 }
        return {
            if let sample = await HeroBackgroundSampler.sample(urls: urls) { return sample }
            if let tmdb = await ArtworkRouter.shared.artworkURL(.hero, for: item),
               let sample = await HeroBackgroundSampler.sample(urls: [tmdb]) { return sample }
            if let poster = item.posterURL,
               let sample = await HeroBackgroundSampler.sample(urls: [poster]) { return sample }
            return nil
        }
        #else
        return nil
        #endif
    }

    /// The hero's action buttons, in visual order.
    private enum HeroButton: Hashable {
        case play, moreInfo, watchlist, next
    }
}
#endif
