#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit
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
    /// Reports the hero action-button row's measured width up the view tree so the
    /// overview/description can cap itself to the same width. Takes the max of any
    /// reported values in a pass (there is only one pills row, so this is just a
    /// straightforward carry-up).
    private struct HeroButtonsWidthKey: PreferenceKey {
        static var defaultValue: CGFloat { 0 }
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }

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
    /// Whether Seerr is currently connected. Gates the featured **Request** CTA:
    /// a not-owned featured title only offers Request (or a request/download
    /// status) when this is `true`; otherwise the slide shows with no primary
    /// button (Play/Resume for ordinary library items is unaffected).
    var seerConnected: Bool = false
    /// One-tap request for a not-owned featured title. Returns the title's new
    /// availability so the pill can flip to Requested/Downloading immediately, or
    /// `nil` if the request failed. `nil` closure disables requesting entirely.
    var onRequest: ((MediaItem) async -> MediaAvailabilityStatus?)? = nil
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
    /// well below the focus engine's page scroll (~480pt) so the artwork keeps its
    /// parallax lag but does NOT fly up: its melted bottom edge stays below the
    /// paging dots as you navigate down. The slow 1.6s glide (see HomeHeroBackdrop)
    /// makes it lag the scroll. Tunable.
    private static let recedeBackdropRise: CGFloat = 240

    /// The app-installed action handler — the SAME one the detail hero and the
    /// long-press context menu use — so the hero's Watchlist button is offered
    /// only when the item's provider supports it and its mutation fans out
    /// exactly like everywhere else.
    @Environment(\.mediaItemActionHandler) private var actionHandler
    @Environment(\.mediaItemActionContext) private var actionContext

    /// The index of the slide currently fronted.
    /// Internal (not private) so the artwork extension in a sibling file can center
    /// its preload window on the current slide; still owned only by this view.
    @State var index: Int = 0
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
    /// Optimistic per-item availability overrides applied the instant the user
    /// taps Request, so the pill flips to Requested/Downloading without waiting
    /// for the next trending refresh. Keyed by `MediaItem.id`; reconciled with the
    /// server's returned status when the request completes.
    @State private var requestOverrides: [String: MediaAvailabilityStatus] = [:]
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
    /// Tracks the physical Left/Right press lifecycle beneath SwiftUI's repeating
    /// move commands. Early repeats are bounced so a normal click stays one-to-one;
    /// after a deliberate hold delay, native rapid navigation resumes.
    @State private var directionalPressGate = HeroDirectionalPressGate()

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
    /// Measured width of the action-button row (the visible pills), used to cap the
    /// overview/description to the same width so the text block never runs wider
    /// than the buttons beneath it. `0` until first measured (overview falls back to
    /// its default cap). Varies per slide as the button set changes.
    @State private var actionButtonsWidth: CGFloat = 0
    /// Bumped on every page so a late metadata fade-in from a *previous* page
    /// can't fire after a newer page has already started.
    @State private var slideToken = 0
    /// Changes only when the curated hero identity set changes. Drives the
    /// low-resolution all-slide preview warm without restarting it on every page.
    @State private var artworkSetToken = 0
    /// Best resolved hero backdrop URL per item id. For episode/season slides
    /// this is the **series-level** hero art (correct show, high-res — matching
    /// the detail page), resolved via ``ArtworkRouter`` and preloaded for the
    /// current slide and its neighbours so a page never animates a placeholder.
    /// Internal (not private) so the artwork extension in a sibling file can read
    /// and populate the resolved-art cache; still owned only by this view.
    @State var resolvedBackdrop: [String: URL] = [:]

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
    /// order. The leading button is the CTA that fits the slide's state — Play,
    /// Request, or a request/download **status** pill — or nothing for a
    /// not-owned featured title while Seerr is disconnected (the slide still
    /// shows, just without a primary button). `.moreInfo` is always present;
    /// `.watchlist` whenever a watchlist toggle applies to the slide's target.
    private func buttons(for item: MediaItem) -> [HeroButton] {
        var result: [HeroButton] = []
        if let primary = primaryButton(for: item) { result.append(primary) }
        result.append(.moreInfo)
        if watchlistAction(for: item) != nil { result.append(.watchlist) }
        // A right-hand chevron on a multi-slide carousel — an affordance that
        // there's more to page through (matching the Apple TV app) and the
        // stable right-most button, so Right only pages the carousel here.
        if items.count > 1 { result.append(.next) }

        // DEBUG (env-gated by PLZHFOCUS_ALTBUTTONS): force the button COUNT to
        // vary between slides so the count-changing page transitions that trigger
        // the focus drop can be reproduced on demand even when every slide would
        // otherwise be 4 buttons. Deterministic per item id (a stable byte-sum
        // parity), so a given slide always has the same count and `selectedButton`
        // clamping stays consistent as you page back and forth. Only removes the
        // Watchlist button (never fabricates one), so `activateSelected()` can
        // never dispatch a bogus action. No effect unless the flag is set.
        if HeroFocusDiagnostics.forceAlternatingButtonCounts {
            let dropWatchlist = item.id.utf8.reduce(0) { $0 &+ Int($1) } % 2 == 0
            if dropWatchlist, let wl = result.firstIndex(of: .watchlist) {
                result.remove(at: wl)
            }
        }
        return result
    }

    /// The effective hero CTA for `item`, applying any optimistic post-tap
    /// availability override so the pill reflects a just-sent request instantly.
    private func heroCTA(for item: MediaItem) -> HeroCTA {
        MediaItem.heroCTA(
            availability: requestOverrides[item.id] ?? item.availability,
            downloadProgress: item.downloadProgress,
            seerConnected: seerConnected
        )
    }

    /// The leading primary button for `item`, or `nil` when the slide offers no
    /// primary action (a not-owned featured title with Seerr disconnected).
    private func primaryButton(for item: MediaItem) -> HeroButton? {
        switch heroCTA(for: item) {
        case .play: return .play
        case .request: return .request
        case .downloading, .requested: return .downloadStatus
        case .unavailable: return nil
        }
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

    private static var screenHeight: CGFloat { HomeHeroLayout.screenHeight }

    private static var screenWidth: CGFloat { HomeHeroLayout.screenWidth }

    /// Distance the content column is lifted off the bottom edge of the
    /// full-screen hero, so the paging dots land in the lower third. Paired with
    /// `HomeView.heroRowOverlap`: the Continue Watching row is pulled up by
    /// slightly less than this, so its title peeks ~40px below the dots. Shared via
    /// ``HomeHeroLayout`` so the loading skeleton lines up 1:1.
    private static let contentBottomInset: CGFloat = HomeHeroLayout.contentBottomInset
    // Pushes the paging dots back down relative to the lifted content column, so
    // the dots sit a little below the action buttons rather than tight against them.
    private static let pagingDotsDrop: CGFloat = 40

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
            artworkSetToken &+= 1
            let oldIdx = index
            let frontedID = oldIDs.indices.contains(index) ? oldIDs[index] : nil
            if let frontedID, let newIdx = newIDs.firstIndex(of: frontedID) {
                index = newIdx
            } else {
                index = min(index, max(0, newIDs.count - 1))
            }
            HeroFocusDiagnostics.emit("items SET-SWAP count \(oldIDs.count)->\(newIDs.count) index \(oldIdx)->\(index) frontedSurvived=\(frontedID.map { newIDs.contains($0) } ?? false) | \(hfState())")
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
            // ...but if the hero is currently RECEDED (focus is down on Continue
            // Watching), re-assert the pause that `restartDwell()` just cleared.
            // Otherwise a background hero recompute (e.g. a Random re-roll or a
            // Continue Watching change) landing while the user browses below would
            // silently resume the carousel and page behind them — defeating the
            // recede pause. Kept coupled to `pausedAt` (not a bare `!receded` task
            // guard) so `resumeFromRecede()` still resumes cleanly on focus return.
            if receded { pauseWhileReceded() }
            // Clamp the logical selection to the new slide's button count so it
            // can never point past the last pill after a set swap. Pure `@State`,
            // so this never touches (or drops) focus.
            if items.indices.contains(index) {
                selectedButton = min(selectedButton, max(0, buttons(for: items[index]).count - 1))
            }
        }
        // Drop optimistic watchlist overrides once the authoritative loaded set
        // agrees, so a stale override can't outlive the real data.
        .onChange(of: watchlistedKeys) { _, keys in
            guard !watchlistOverrides.isEmpty else { return }
            watchlistOverrides = watchlistOverrides.filter { key, value in
                value != keys.contains(key)
            }
        }
        // Drop optimistic request overrides once Home's in-place featured refresh
        // reports an authoritative status that reflects the landed request (the
        // server now tracks it: pending/processing/partially/available). Otherwise
        // a just-tapped "Requested" override would mask the real "Downloading n%"
        // /Play the refresh brings in. Keyed on the items' (id, availability) so it
        // only fires when a real status actually changes.
        .onChange(of: items.map { RequestStatusSignature(id: $0.id, availability: $0.availability) }) { _, _ in
            guard !requestOverrides.isEmpty else { return }
            for item in items {
                if let real = item.availability, real != .unknown, real != .deleted {
                    requestOverrides[item.id] = nil
                }
            }
        }
        // Keep only the fronted slide's current warm pass alive. Rapid paging
        // cancels the old five-slide window before it can keep downloading and
        // decoding artwork the user has already skipped.
        .task(id: ArtworkResolutionKey(slideToken: slideToken, index: index)) {
            await resolveArtwork(around: index)
        }
        // A cheap 768px preview for every configured hero slide makes even a
        // 20-item fly-through immediate. This task survives page changes; all work
        // stays behind the shared background limiter and full hero art still has
        // foreground priority.
        .task(id: artworkSetToken) {
            await warmHeroPreviews()
        }
        // Provider logos are much smaller than backdrops, but still require a
        // network fetch plus decode/analysis. Warm them in likely paging order so
        // each slide arrives with its final identity instead of replacing a settled
        // text title. The shared limiter keeps this behind foreground artwork.
        .task(id: artworkSetToken) {
            await warmHeroLogos()
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
            HeroFocusDiagnostics.emit("auto-advance FIRE (from idx=\(index)) | \(hfState())")
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
                // The recede rise. The backdrop is screen-pinned by its own
                // `.ignoresSafeArea(.top)` breakout (it does NOT scroll with the
                // page), so it needs no scroll counter. Drive it purely off
                // `receded`: 0 at rest, a clean rise when receded, animated inside
                // HomeHeroBackdrop so it lags the content lift (the Apple TV feel).
                // The bottom-melt shaping (theme-aware height, left weighting) lives
                // entirely inside HomeHeroBackdrop's dissolve now.
                recedeLift: receded ? Self.recedeBackdropRise : 0,
                // On recede, melt the right side into the page like the left so the
                // whole backdrop blends together while browsing the rows below.
                receded: receded
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

    /// Reserved focus-region size for the env-gated UIKit foreground path
    /// (``HeroForegroundConfig``). When the UIKit view draws the pill visuals, the
    /// SwiftUI action row keeps only its (invisible) focus leaf; this fixed region
    /// holds its place in the lower third. Left/Right are logical (resolved via the
    /// guards), so exact pixel overlap with the drawn pills isn't required — a
    /// deliberate POC simplification.
    private static let uikitFocusRegionWidth: CGFloat = 620
    private static let uikitFocusRegionHeight: CGFloat = 76
    /// Reserved paging-dots footprint below the focus region on the UIKit-foreground
    /// path (the UIKit view draws the real dots); keeps the focus leaf at the same
    /// vertical position as the SwiftUI path.
    private static let uikitDotsReserve: CGFloat = 24

    /// The base of the action row: the visible SwiftUI pills (standard path) or a
    /// reserved clear focus region (UIKit-foreground path, which draws the pills).
    /// The single focus leaf + row identity are attached by the caller to whichever
    /// base this returns, so the focus/accessibility overlay stays canonical.
    @ViewBuilder
    private func pillsBase(for item: MediaItem, itemButtons: [HeroButton], drawPills: Bool) -> some View {
        if drawPills {
            HStack(spacing: 24) {
                ForEach(Array(itemButtons.enumerated()), id: \.element) { offset, button in
                    heroButtonVisual(button, for: item, selected: focus != nil && selectedButton == offset)
                }
            }
            // Report the pills' natural width up so the overview above can cap itself
            // to the button row (see `actionButtonsWidth`). Measured on the pills
            // themselves — NOT the enclosing action row, which is `maxWidth: .infinity`.
            .background {
                GeometryReader { geo in
                    Color.clear.preference(key: HeroButtonsWidthKey.self, value: geo.size.width)
                }
            }
            .opacity(metadataVisible ? 1 : 0)
            // Snap the pills' hide instantly (matches the metadata above); the
            // delayed fade-IN still animates.
            .transaction { if !metadataVisible { $0.animation = nil } }
            .allowsHitTesting(false)
        } else {
            Color.clear.frame(width: Self.uikitFocusRegionWidth, height: Self.uikitFocusRegionHeight)
        }
    }

    @ViewBuilder
    private func content(for item: MediaItem) -> some View {
        if HeroForegroundConfig.useUIKitForeground {
            uikitContent(for: item)
        } else {
            swiftUIContent(for: item)
        }
    }

    @ViewBuilder
    private func swiftUIContent(for item: MediaItem) -> some View {
        let hideText = spoilerSettings.shouldHideText(for: item)
        VStack(alignment: .leading, spacing: 12) {
            // Absorbs the vertical slack at the TOP of the (fixed-height) column so
            // the bottom block — logo/metadata/overview + buttons + dots — is pinned
            // to an integer offset from the frame's bottom edge. Previously the whole
            // column was bottom-anchored as one unit, so the metadata block's
            // *fractional*, per-slide-varying height (different overviews / metadata)
            // nudged the column's rounded origin by 1–2pt every page — the reported
            // paging jitter where the buttons and dots crept up/down. With this
            // Spacer taking the fractional slack, a taller/shorter metadata block
            // only changes the Spacer's height; the buttons and dots stay put.
            Spacer(minLength: 0)

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
                    backgroundSample: backgroundSample(for: item),
                    // Cap the logo image to the action-button row width (measured
                    // below) so it never runs wider than the buttons beneath it —
                    // matching the title/overview. Falls back to the component's
                    // default until first measured.
                    maxWidth: actionButtonsWidth > 0 ? actionButtonsWidth : 620,
                    // The parent keeps metadata hidden for 280ms during a wipe. A
                    // cache-hot logo lands inside that window; a later result warms
                    // the next visit but never pops into an already-settled slide.
                    presentationPolicy: .onArrival(maximumWait: 0.2)
                ) {
                    Text(hideText ? spoilerSettings.maskedTitle(for: item) : item.title)
                        .font(.system(size: 64, weight: .bold))
                        .lineLimit(2)
                        .minimumScaleFactor(0.5)
                        .multilineTextAlignment(.leading)
                        // Cap the text title to the action-button row width (measured
                        // below) so it wraps to fit within the buttons, like the
                        // overview. Falls back to the old cap until first measured.
                        .frame(maxWidth: actionButtonsWidth > 0 ? actionButtonsWidth : 1200, alignment: .leading)
                        .contentTransition(.opacity)
                }
                .id("logo-\(item.id)")

                metadataLine(for: item)
                    .modifier(HeroTextLegibilityShadow(colorScheme: colorScheme))

                if !hideText, let overview = item.overview {
                    Text(overview)
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                        .lineSpacing(2)
                        .lineLimit(3, reservesSpace: true)
                        // Cap the description to the action-button row width (measured
                        // below) so it never runs wider than the buttons beneath it.
                        // Falls back to the previous fixed cap until first measured.
                        .frame(maxWidth: actionButtonsWidth > 0 ? actionButtonsWidth : 960, alignment: .topLeading)
                        // Subtle legibility shadow so the description reads clearly
                        // over the (now more dissolved) lower hero — see modifier.
                        .modifier(HeroTextLegibilityShadow(colorScheme: colorScheme))
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
        // Fixed, INTEGER height for the column so its origin never rounds to a
        // different pixel per slide (the paging-jitter root cause). The height is
        // the full hero height minus the bottom inset; the top Spacer inside then
        // absorbs the fractional slack, and the bottom block (buttons + dots) sits
        // at an integer offset from this frame's bottom. `screenHeight` and
        // `contentBottomInset` are whole numbers, so the frame bottom is integral.
        .frame(height: HomeHeroLayout.screenHeight - Self.contentBottomInset)
        .frame(maxWidth: .infinity, alignment: .leading)
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
        // Cap the overview to the button-row width: adopt the pills' measured width.
        .onPreferenceChange(HeroButtonsWidthKey.self) { width in
            if width > 0 { actionButtonsWidth = width }
        }
    }

    /// Env-gated (``HeroForegroundConfig``) imperative **UIKit** visual foreground.
    /// The persistent ``HeroForegroundRepresentable`` draws the logo/metadata/
    /// overview/pill/dot *visuals* imperatively (no SwiftUI foreground rebuild per
    /// page — the measured hitch source). The SwiftUI layer here keeps ONLY the
    /// canonical focus/navigation/accessibility overlay (`actionRow(drawPills:false)`
    /// plus the L/R guards) so focus, selection dispatch, recede and VoiceOver are
    /// byte-for-byte unchanged. Both bottom-anchor to the same column frame.
    @ViewBuilder
    private func uikitContent(for item: MediaItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Spacer(minLength: 0)
            // Zero-height recede target (identical to the SwiftUI path).
            Color.clear
                .frame(height: 0)
                .id(Self.recedeAnchorID)
            // Focus/accessibility overlay only — the UIKit view draws the pills.
            actionRow(for: item, drawPills: false)
            // Reserve the paging-dots footprint so the focus region sits at the same
            // height as the SwiftUI path (the UIKit view draws the real dots).
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: Self.uikitDotsReserve)
        }
        .frame(height: HomeHeroLayout.screenHeight - Self.contentBottomInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The imperative UIKit visual layer fills the same column frame, bottom-
        // anchored, behind the focus overlay. Instantiated only on this gated path,
        // so the standard SwiftUI path pays nothing.
        .background(alignment: .bottomLeading) {
            HeroForegroundRepresentable(
                model: foregroundModel(for: item),
                neighbours: foregroundNeighbours(for: item),
                metadataVisible: metadataVisible,
                width: HomeHeroLayout.screenWidth,
                height: HomeHeroLayout.screenHeight - Self.contentBottomInset
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .padding(.trailing, PlozzTheme.Metrics.screenPadding)
        .padding(.leading, PlozzTheme.Metrics.heroLeadingPadding)
        .padding(.bottom, Self.contentBottomInset)
        .offset(y: receded ? -Self.recedeContentLift : 0)
    }

    /// Builds the current slide's ``HeroForegroundModel`` from the view's already
    /// resolved focus/selection/CTA/spoiler state (pure mapping lives in
    /// ``HeroForegroundModelBuilder``).
    private func foregroundModel(for item: MediaItem) -> HeroForegroundModel {
        // Only the fronted slide carries the live auto-advance dwell so its active
        // paging pill can render the "time until next page" gauge; neighbours are
        // built neutral and re-applied with the real dwell when they front.
        foregroundModel(
            for: item,
            selectedIndex: selectedButton,
            heroFocused: focus != nil,
            dotsAutoAdvance: settings.autoAdvance && items.count > 1,
            dotsDwellStart: dwellStart,
            dotsDwellDuration: Double(settings.autoAdvanceSeconds),
            dotsPausedAt: pausedAt
        )
    }

    private func foregroundModel(
        for item: MediaItem,
        selectedIndex: Int,
        heroFocused: Bool,
        dotsAutoAdvance: Bool = false,
        dotsDwellStart: Date? = nil,
        dotsDwellDuration: Double = 0,
        dotsPausedAt: Date? = nil
    ) -> HeroForegroundModel {
        let hideText = spoilerSettings.shouldHideText(for: item)
        let masked = hideText ? spoilerSettings.maskedTitle(for: item) : nil
        let slideIndex = items.firstIndex(where: { $0.id == item.id }) ?? index
        return HeroForegroundModelBuilder.model(
            item: item,
            overviewVisible: !hideText,
            maskedTitle: masked,
            pillInputs: foregroundPillInputs(for: item),
            selectedIndex: selectedIndex,
            heroFocused: heroFocused,
            slideCount: items.count,
            slideIndex: slideIndex,
            dotsAutoAdvance: dotsAutoAdvance,
            dotsDwellStart: dotsDwellStart,
            dotsDwellDuration: dotsDwellDuration,
            dotsPausedAt: dotsPausedAt
        )
    }

    /// Maps the slide's `buttons(for:)` (identical order to the SwiftUI pills) into
    /// the pure pill inputs, resolving the same dynamic state the SwiftUI pills use
    /// (resume progress, download %, watchlist fill).
    private func foregroundPillInputs(for item: MediaItem) -> [HeroForegroundModelBuilder.PillInput] {
        buttons(for: item).map { button in
            switch button {
            case .play:
                let resume = item.resumeProgressFraction
                return .init(
                    kind: .play,
                    resumeProgress: resume,
                    isResume: resume != nil,
                    resumeRemainingText: item.resumeRemainingText
                )
            case .request:
                return .init(kind: .request)
            case .downloadStatus:
                if case let .downloading(progress) = heroCTA(for: item) {
                    return .init(kind: .downloadStatus, downloadProgress: progress)
                }
                return .init(kind: .downloadStatus)
            case .moreInfo:
                return .init(kind: .moreInfo)
            case .watchlist:
                return .init(kind: .watchlist, isFavorite: watchlistTarget(for: item).isFavorite)
            case .next:
                return .init(kind: .next)
            }
        }
    }

    /// Bounded neighbour models (previous / next slide) handed to the coordinator to
    /// prepare off-transition so a page finds the model + logo already warm. Built
    /// with a neutral selection/focus (the real page re-applies the correct one).
    private func foregroundNeighbours(for item: MediaItem) -> [HeroForegroundModel] {
        guard items.count > 1 else { return [] }
        let current = items.firstIndex(where: { $0.id == item.id }) ?? index
        let previous = (current - 1 + items.count) % items.count
        let next = (current + 1) % items.count
        var seen: Set<Int> = [current]
        var result: [HeroForegroundModel] = []
        for neighbour in [previous, next] where !seen.contains(neighbour) && items.indices.contains(neighbour) {
            seen.insert(neighbour)
            result.append(foregroundModel(for: items[neighbour], selectedIndex: 0, heroFocused: false))
        }
        return result
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
    private func actionRow(for item: MediaItem, drawPills: Bool = true) -> some View {
        let itemButtons = buttons(for: item)
        // Named VoiceOver actions for *every* visible pill (the row is a single
        // a11y element, so without these only the highlighted action would be
        // reachable). Order matches the visible pills.
        let a11yActions: [(String, () -> Void)] = itemButtons.map { button in
            switch button {
            case .play: return (item.resumeProgressFraction != nil ? "Resume" : "Play", { onPlay(item) })
            case .request: return ("Request", { performRequest(for: item) })
            case .downloadStatus: return (downloadStatusText(for: item), {})
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
            // Invisible directional target, just left of the pills and inside the
            // same focus section. Native focus movement preserves the familiar tvOS
            // click sound. The UIKit surface tracks physical press phases so only
            // the first move from one held press is handled; touch-surface swipes
            // still pass through normally. It steps aside only at the one escape
            // spot (first item, left-most button, sidebar nav).
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
            // (it lives on the overlay below), so fading these to opacity 0 can't
            // drop focus or shift the scroll.
            //
            // The button COUNT can differ per slide (e.g. a Continue Watching slide
            // has no Watchlist action), which once caused an intermittent focus
            // drop when paging between different-count slides. That is fixed by
            // `restoreFocusAfterPage()` (a next-tick focus reassert), NOT by
            // stabilising this row — and the pills are hidden (opacity 0, snapped)
            // during the ~280ms page window anyway, so a one-tick focus/highlight
            // blip here is invisible. So this stays the simple, direct row.
            pillsBase(for: item, itemButtons: itemButtons, drawPills: drawPills)
            // ── The single hero focus target: an always-opaque, invisible SwiftUI
            // leaf layered *over* the pills. Because `.overlay` is applied after the
            // pills' `.opacity`, it stays fully opaque and focusable even while the
            // pills fade to 0 — so focus (and therefore the scroll position) is
            // pinned throughout a page, while the buttons still disappear and
            // reappear. There is NO per-button `@FocusState`.
            //
            // A passive UIKit recognizer attached to the window observes physical
            // Left/Right begin/end phases without becoming the focus leaf or
            // recognizing/cancelling the gesture. The guards below use that
            // lifecycle to accept only the first move from one held click while
            // native focus feedback and indirect-touch swipes remain unchanged.
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
                    .background {
                        HeroDirectionalPressMonitor(
                            capturesLeft: !allowsSidebarEscape,
                            gate: directionalPressGate
                        )
                    }
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

            // Invisible directional target just right of the pills. Physical clicks
            // retain native focus feedback and are de-repeated by the press gate;
            // touch-surface swipes route through the same `handleRight()` path.
            // Unlike the left guard it is always focusable: Right never escapes.
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
            let oldName = old.map { "\($0)" } ?? "nil"
            let newName = new.map { "\($0)" } ?? "nil"
            HeroFocusDiagnostics.emit("focus \(oldName)->\(newName) | \(hfState())")
            switch new {
            case .leftGuard:
                if directionalPressGate.shouldHandle(.left) {
                    handleLeft()
                } else {
                    HeroFocusDiagnostics.emit("suppressed repeated physical Left")
                    noteInteraction()
                    focus = .row
                }
            case .rightGuard:
                if directionalPressGate.shouldHandle(.right) {
                    handleRight()
                } else {
                    HeroFocusDiagnostics.emit("suppressed repeated physical Right")
                    noteInteraction()
                    focus = .row
                }
            case .row:
                // Focus arriving into the hero from *outside* (a row below / the
                // tab bar): snap back to full-screen and scroll the page to the top.
                // Auto-advance pause/resume is NOT driven from here — it's keyed off
                // the `receded` state (see `.onChange(of: receded)` below), which is
                // the reliable "focus moved DOWN to Continue Watching" signal.
                if old == nil {
                    HeroFocusDiagnostics.emit("focus ENTER hero (row, from outside) | \(hfState())")
                    if let item = current {
                        selectedButton = min(selectedButton, max(0, buttons(for: item).count - 1))
                    }
                    onFocusGained()
                }
            case .none:
                // Focus left the hero (down to a row, up to the tab bar, or out to
                // the sidebar). Nothing to do here: the auto-advance pause is keyed
                // off `receded` (down-only), and the recede itself is driven by the
                // page scroll in `HomeView`.
                HeroFocusDiagnostics.emit("focus LEFT hero (->nil) from \(oldName) | \(hfState())")
            }
        }
        // Pause the auto-advance whenever the hero is RECEDED — i.e. focus moved
        // DOWN onto Continue Watching (the page scrolled past the recede threshold;
        // see `HomeView`). Matches the Apple TV app: the hero stops rotating while
        // you browse the row beneath it, and resumes (with a fresh dwell) when
        // focus returns to the hero. Moving focus UP to the tab bar (or LEFT to the
        // sidebar) does NOT scroll the page down, so `receded` stays false there and
        // the carousel keeps playing — exactly the requested behavior.
        .onChange(of: receded) { _, isReceded in
            if isReceded { pauseWhileReceded() } else { resumeFromRecede() }
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

    /// Whether the invisible left swipe fallback should be focusable. It captures
    /// a focus-engine move so the hero handles it internally instead of escaping
    /// to the sidebar. It steps aside (non-focusable) *only* at the escape spot AND
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
    /// It does NOT resolve paging for any direction: Left/Right clicks use the
    /// UIKit press surface, touch swipes use the invisible focus fallbacks, Up is
    /// left to the system, and Down-recede is driven by the page scroll in
    /// `HomeView`. It only observes (never consumes) the move.
    private func handleMove() {
        noteInteraction()
    }

    /// One-line snapshot of the hero's focus/paging state for
    /// ``HeroFocusDiagnostics``. Reads only view state (no mutation), so it is
    /// safe to call from any focus/paging site. Temporary debugging aid.
    private func hfState() -> String {
        let btnCount = current.map { buttons(for: $0).count } ?? 0
        let focusName = focus.map { "\($0)" } ?? "nil"
        return "idx=\(index)/\(items.count) selBtn=\(selectedButton)/\(btnCount) "
            + "focus=\(focusName) leftGuardActive=\(leftGuardActive) "
            + "sidebarEscape=\(allowsSidebarEscape) metaVisible=\(metadataVisible)"
    }

    /// Resolves one discrete Left click from the UIKit surface or a swipe captured
    /// by the invisible left fallback, then ensures focus is on the pill row.
    /// Interior moves adjust `selectedButton`; `.advance` pages backward. The one
    /// `.escape` case (first item, left-most button, sidebar) cannot arrive from a
    /// swipe because the guard is non-focusable there; Left falls through instead.
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
        HeroFocusDiagnostics.emit("handleLeft outcome=\(outcome) | \(hfState())")
        switch outcome {
        case let .moveButton(newIndex):
            selectedButton = newIndex
        case let .advance(toItem, keepButton):
            page(to: toItem, keepButton: keepButton, forward: false)
            restoreFocusAfterPage()
        case .escape, .blocked:
            break
        }
    }

    /// Backstop for the intermittent focus drop on a page that changes the hero's
    /// action-button count. `handleLeft()`/`handleRight()` re-pin focus with the
    /// synchronous `defer { focus = .row }` above — but that runs from INSIDE
    /// `focus`'s own `onChange` (we're handling the guard bounce) and in the SAME
    /// transaction that `page()` swaps `index` (new pill content). Device tracing
    /// (`PLZHFOCUS`) proved that on a page where the button count changes the extra
    /// layout work makes the tvOS focus engine DROP that reassignment: focus lands
    /// on `nil` and is stranded ~1–2s until the next press, then returns on the
    /// wrong control (the reported bug). Reasserting `.row` on the NEXT runloop
    /// tick — after SwiftUI has committed the paged layout — lands reliably because
    /// it no longer races the content change. It only fires if focus was actually
    /// dropped (`== nil`) AND no newer page has happened since (`advanceToken`
    /// unchanged), and is a no-op on the ~80% of pages where the synchronous re-pin
    /// already worked (so it adds no flicker there). Note the `advanceToken` guard
    /// rules out a *newer page* superseding this reassert; it does NOT by itself
    /// distinguish an engine-dropped re-pin from a deliberate non-paging exit (Down
    /// to a row / Up to the tab bar / Left to the sidebar all also leave
    /// `focus == nil`). We rely on timing instead: this block drains on the very
    /// next main-runloop turn — well before a second physical remote press can
    /// arrive (~100ms+) — so a deliberate exit that happens *after* the restore
    /// still wins normally. (A multi-frame main-thread stall could theoretically
    /// let a second press land first; not observed on device.)
    private func restoreFocusAfterPage() {
        let token = advanceToken
        DispatchQueue.main.async {
            guard focus == nil, token == advanceToken else { return }
            HeroFocusDiagnostics.emit("restoreFocusAfterPage: focus was dropped, reasserting .row | \(hfState())")
            focus = .row
        }
    }

    /// Resolves one discrete Right click from the UIKit surface or a swipe captured
    /// by the invisible right fallback, then ensures focus is on the pill row.
    /// Interior moves adjust `selectedButton`; `.advance` pages forward. Right
    /// never escapes, so there is no fall-through case.
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
        HeroFocusDiagnostics.emit("handleRight outcome=\(outcome) | \(hfState())")
        switch outcome {
        case let .moveButton(newIndex):
            selectedButton = newIndex
        case let .advance(toItem, keepButton):
            page(to: toItem, keepButton: keepButton, forward: true)
            restoreFocusAfterPage()
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
        case .request: performRequest(for: item)
        case .downloadStatus: break // informational status pill — no action
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

    /// Sends a one-tap Seerr request for a not-owned featured title, flipping the
    /// pill to a Requested/Downloading status immediately (optimistic) and then
    /// reconciling with the server's returned availability. A failed request
    /// clears the override so the Request button returns for a retry.
    private func performRequest(for item: MediaItem) {
        guard let onRequest else { return }
        noteInteraction()
        requestOverrides[item.id] = .pending
        Task {
            if let status = await onRequest(item) {
                requestOverrides[item.id] = status
            } else {
                requestOverrides[item.id] = nil
            }
        }
    }

    /// Spoken/label text for a request/download status pill.
    private func downloadStatusText(for item: MediaItem) -> String {
        switch heroCTA(for: item) {
        case let .downloading(progress): return "Downloading \(Int((progress * 100).rounded()))%"
        default: return "Requested"
        }
    }

    /// Inner label of the request/download status pill: a download glyph plus a
    /// live progress bar + percentage while actually fetching (reusing the shared
    /// resume capsule so it matches the Play button's bar), or a plain "Requested"
    /// status for a request that isn't downloading yet.
    @ViewBuilder
    private func downloadStatusLabel(for item: MediaItem, selected: Bool) -> some View {
        switch heroCTA(for: item) {
        case let .downloading(progress):
            HStack(spacing: 16) {
                Image(systemName: "arrow.down.circle")
                ResumeProgressCapsule(progress: progress, onLight: selected || colorScheme == .light)
                Text("\(Int((progress * 100).rounded()))%")
                    .lineLimit(1)
            }
            .font(.system(size: 28, weight: .semibold))
        default:
            Label("Requested", systemImage: "clock")
                .font(.system(size: 28, weight: .semibold))
        }
    }

    /// VoiceOver label for the row's currently-selected action.
    private func accessibilityLabel(for item: MediaItem) -> String {
        let itemButtons = buttons(for: item)
        guard itemButtons.indices.contains(selectedButton) else { return item.title }
        let name: String
        switch itemButtons[selectedButton] {
        case .play: name = item.resumeProgressFraction != nil ? "Resume" : "Play"
        case .request: name = "Request"
        case .downloadStatus: name = downloadStatusText(for: item)
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
            heroPill(selected: selected) {
                PlayResumeButtonLabel(
                    title: item.resumeProgressFraction != nil ? "Resume" : "Play",
                    progress: item.resumeProgressFraction,
                    remainingText: item.resumeRemainingText,
                    onLight: selected || colorScheme == .light
                )
                .font(.system(size: 28, weight: .semibold))
            }
        case .request:
            heroPill(selected: selected) {
                Label("Request", systemImage: "plus.circle")
                    .font(.system(size: 28, weight: .semibold))
            }
        case .downloadStatus:
            heroPill(selected: selected) {
                downloadStatusLabel(for: item, selected: selected)
            }
        case .moreInfo:
            heroPill(selected: selected) {
                Image(systemName: "info.circle")
                    .font(.system(size: 28, weight: .semibold))
                    .frame(width: 34, height: 34)
            }
        case .watchlist:
            let target = watchlistTarget(for: item)
            heroPill(selected: selected) {
                Image(systemName: target.isFavorite ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 28, weight: .semibold))
                    .symbolEffect(.bounce, value: target.isFavorite)
                    .frame(width: 34, height: 34)
            }
        case .next:
            heroPill(selected: selected) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 28, weight: .semibold))
                    .frame(width: 34, height: 34)
            }
        }
    }

    /// The glass-pill chrome shared by every hero action. Identity-stable (only
    /// animatable properties vary with `selected`), so nothing here can disturb
    /// focus. Every idle pill is the same translucent glass; the selected pill (when
    /// the hero holds focus) gets the bright white fill + dark glyph + lift.
    /// Colour/fill snap instantly (no comet trail); only the scale/shadow lift
    /// animates as selection moves.
    @ViewBuilder
    private func heroPill<Content: View>(
        selected: Bool,
        @ViewBuilder _ label: () -> Content
    ) -> some View {
        let shape = Capsule(style: .continuous)
        // Glyph/label tint. When focused the pill is a bright WHITE platter, so the
        // glyph is black. When idle it sits on Liquid Glass — which renders LIGHT
        // (frosted) in light mode and dark in dark mode — so the glyph must follow
        // the appearance: dark ink in light mode, white in dark mode. (Forcing white
        // unconditionally made idle pills white-on-light = invisible in light mode;
        // the frosted glass lightens whatever art is behind it, so the dark backdrop
        // doesn't rescue it.) This also matches the Play button's `onLight` flag, so
        // the resume progress bar and its glyph/text now flip together.
        let idleTint: Color = colorScheme == .light ? .black : .white
        label()
            .foregroundStyle(selected ? Color.black : idleTint)
            .transaction { $0.animation = nil }
            .padding(.horizontal, 30)
            .padding(.vertical, 18)
            .background {
                ZStack {
                    heroPillIdleBackground(shape: shape)
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
    private func heroPillIdleBackground(shape: Capsule) -> some View {
        if #available(tvOS 26.0, *) {
            // Liquid Glass for every idle pill.
            shape.fill(.clear)
                .glassEffect(.regular, in: shape)
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
        guard items.indices.contains(toItem), toItem != index else {
            HeroFocusDiagnostics.emit("page IGNORED to=\(toItem) keepButton=\(keepButton) forward=\(isForward) | \(hfState())")
            return
        }
        HeroFocusDiagnostics.emit("page BEGIN from=\(index) to=\(toItem) keepButton=\(keepButton) forward=\(isForward) | \(hfState())")
        // Perf marker (PLZPERF stream only): lets a capture attribute frame hitches
        // to specific slide transitions vs idle. Zero-cost unless PLZPERF_STDOUT=1.
        HomePerfDiagnostics.emitLine("TRANSITION from=\(index) to=\(toItem) forward=\(isForward)")
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

    /// Pauses the auto-advance because the hero has RECEDED — focus moved DOWN to
    /// Continue Watching (see the `receded` onChange). Unlike ``noteInteraction()``
    /// it does NOT arm the idle-resume timer — it cancels any pending one — so the
    /// carousel stays paused for as long as the hero is receded and resumes only
    /// when focus returns to the hero (see ``resumeFromRecede()``). Bumping
    /// `runEpoch` re-keys the fire `.task` into its paused (no-op) branch.
    private func pauseWhileReceded() {
        guard settings.autoAdvance, items.count > 1 else { return }
        resumeWork?.cancel()
        resumeWork = nil
        if pausedAt == nil {
            pausedAt = Date()
            runEpoch &+= 1
        }
    }

    /// Resumes the auto-advance when the hero un-recedes (focus returns to the hero
    /// from Continue Watching), the mirror of ``pauseWhileReceded()``. Gives the
    /// slide the user lands back on a fresh full dwell and re-keys the fire `.task`.
    /// No-op if the carousel wasn't paused.
    private func resumeFromRecede() {
        guard settings.autoAdvance, items.count > 1, pausedAt != nil else { return }
        restartDwell()
        runEpoch &+= 1
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
        // Never let the idle timer (from an earlier in-hero interaction) restart
        // paging while the hero is receded — focus is down on Continue Watching and
        // must not have the carousel page behind it. The `receded` onChange resumes
        // once focus returns to the hero.
        guard !receded else { return }
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
            HeroFocusDiagnostics.emit("metadata fade-in (token=\(token)) | \(hfState())")
        }
    }

    // MARK: - Paging dots

    @ViewBuilder
    private var pagingDots: some View {
        if items.count > 1 {
            HStack(spacing: Self.dotSpacing) {
                // Windowed: at most `maxVisibleDots` are shown. When there are more
                // slides than fit, the row scrolls and the dots nearest a hidden
                // edge shrink to signal "more this way" (see `HeroPagingDots`). Keyed
                // by the slide's real index so a scroll SLIDES the shared dots (and
                // fades the one leaving / entering) rather than snapping.
                ForEach(HeroPagingDots.layout(count: items.count, index: index, maxVisible: Self.maxVisibleDots, edgeShrink: Self.edgeShrinkCount)) { dot in
                    pagingIndicator(active: dot.index == index, scale: Self.dotScale(for: dot.size))
                }
            }
            // Pin the row to the dot height so its vertical centering can NEVER
            // change. Without this, the active dot's animating frame let the HStack
            // recompute a sub-pixel-different vertical center mid-morph, drifting the
            // dots down a few px on every page (the reported jitter). When windowed,
            // also pin the WIDTH: a scroll momentarily renders a 9th (entering/leaving)
            // dot, which would otherwise widen the row and make the glass pill breathe
            // — the fixed width holds the pill steady while the extra dot fades at the
            // edge.
            .frame(width: windowedRowWidth, height: Self.dotSize)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            // Liquid Glass rounded container so the indicators stay legible over any
            // backdrop (matches the hero action pills' glass treatment).
            .background { pagingDotsGlass(shape: Capsule()) }
            .padding(.top, 10)
            // ONE coordinated morph for the whole row, keyed on the fronted slide.
            // Both the outgoing and incoming dot (and their fills) animate in a
            // single transaction, so there are no dueling per-dot `.animation`s whose
            // independent interpolations nudged each dot's origin on both axes. The
            // row width is constant while windowed (always `maxVisibleDots` fixed-pitch
            // slots, exactly one of which is the wide pill), so the glass pill never
            // resizes; the shrunk edge dots scale WITHIN their fixed slots.
            .animation(.easeInOut(duration: Self.dotMorph), value: index)
            .accessibilityHidden(true)
        }
    }

    private static let dotSize: CGFloat = 10
    private static let dotSpacing: CGFloat = 12
    private static let activeDotWidth: CGFloat = 30
    /// Duration of the simultaneous dot→pill / pill→dot open/close on a page.
    private static let dotMorph: Double = 0.3

    /// Maximum page indicators shown at once. Beyond this the row becomes a scrolling
    /// window with shrinking edge dots — a fixed UX cap independent of how many
    /// titles the user lets the hero rotate through (`HeroSettings.maxItems`).
    private static let maxVisibleDots = 8
    /// How many dots shrink on each edge that has hidden content (outermost first).
    private static let edgeShrinkCount = 2

    /// Fixed width of the windowed dot row (nil when not windowed, so the classic
    /// row sizes naturally to its dots). Exactly `maxVisibleDots` slots: one active
    /// pill plus the rest full-size dots, with uniform spacing. Holding this constant
    /// keeps the glass pill from resizing when a scroll transiently renders an extra
    /// entering/leaving dot.
    private var windowedRowWidth: CGFloat? {
        guard items.count > Self.maxVisibleDots else { return nil }
        let others = CGFloat(Self.maxVisibleDots - 1)
        return others * Self.dotSize + Self.activeDotWidth + others * Self.dotSpacing
    }

    /// Theme-aware ink for the paging indicators — dark in light mode, white in dark
    /// mode — mirroring the action pills' `idleTint`. The dots sit on the same
    /// Liquid Glass (which renders light/frosted in light mode), so hardcoded white
    /// dots washed out in light mode; this keeps them legible in both appearances.
    private var dotTint: Color { colorScheme == .light ? .black : .white }

    /// One rendered page indicator: the slide it represents and how large to draw it
    /// (1 = full dot/pill, <1 = a shrunk edge dot signalling more content that way).
    /// Maps `HeroPagingDots.Size` (the pure windowing result) to a render scale. The
    /// falloff is deliberately gentle — the outermost dot stays clearly visible (a
    /// tiny speck read as "too small" on device) rather than shrinking to a dot.
    private static func dotScale(for size: HeroPagingDots.Size) -> CGFloat {
        switch size {
        case .full: return 1.0
        case .medium: return 0.78   // second-from-edge
        case .small: return 0.55    // outermost edge
        }
    }

    /// A single page indicator. It is always the same `Capsule` so its width can
    /// smoothly animate between a dot (inactive) and a pill (active) — the active
    /// one opening exactly as the outgoing one closes, keeping the container width
    /// constant. The active pill fills left→right as the auto-advance dwell elapses
    /// (a live "time until next page" gauge). The width morph is animated once, by
    /// the container's `value: index` animation — NOT per-dot here — so the outgoing
    /// and incoming dots interpolate in the same transaction and never drift.
    ///
    /// `scale` shrinks a non-active edge dot toward the hidden-content side. The
    /// shrunk circle is rendered INSIDE a full-size (`dotSize`) slot so the row's
    /// pitch and total width stay constant as dots shrink/grow — the glass pill
    /// never resizes, and there's no per-page width jitter.
    private func pagingIndicator(active: Bool, scale: CGFloat) -> some View {
        Capsule()
            .fill(dotTint.opacity(0.28))
            .overlay(alignment: .leading) {
                activeDotFill(active: active, trackWidth: Self.activeDotWidth, height: Self.dotSize)
            }
            .frame(width: active ? Self.activeDotWidth : Self.dotSize * scale, height: Self.dotSize * scale)
            .clipShape(Capsule())
            // Reserve a full-size slot so the pitch is uniform regardless of `scale`.
            .frame(width: active ? Self.activeDotWidth : Self.dotSize, height: Self.dotSize)
    }

    /// The bright progress fill inside an indicator. Every dot keeps stable view
    /// identity for the coordinated morph, but only the active dot's timeline ticks;
    /// inactive dots stay paused at zero instead of each invalidating at 30 Hz.
    private func activeDotFill(active: Bool, trackWidth: CGFloat, height: CGFloat) -> some View {
        TimelineView(.animation(
            minimumInterval: 1.0 / 30.0,
            paused: !active || !settings.autoAdvance || pausedAt != nil
        )) { timeline in
            Capsule()
                .fill(dotTint)
                .frame(
                    width: brightFillWidth(active: active, trackWidth: trackWidth, height: height, now: timeline.date),
                    height: height
                )
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
    /// tvOS 26+, `.ultraThinMaterial` below (mirrors `heroPillIdleBackground`). The
    /// container width is constant across pages, so this pill never resizes — the
    /// paging jitter was the dots' animation, not this background.
    @ViewBuilder
    private func pagingDotsGlass(shape: Capsule) -> some View {
        if #available(tvOS 26.0, *) {
            shape.fill(.clear).glassEffect(.regular, in: shape)
        } else {
            shape.fill(.ultraThinMaterial)
        }
    }

    /// The hero's action buttons, in visual order.
    private enum HeroButton: Hashable {
        case play, request, downloadStatus, moreInfo, watchlist, next
    }

    /// A cheap `Equatable` fingerprint of a featured item's request state, so the
    /// override-reconciliation `onChange` fires only when a real status changes
    /// (not on unrelated re-renders or download-progress ticks).
    private struct RequestStatusSignature: Equatable {
        let id: String
        let availability: MediaAvailabilityStatus?
    }

    private struct ArtworkResolutionKey: Equatable {
        let slideToken: Int
        let index: Int
    }
}

#endif
