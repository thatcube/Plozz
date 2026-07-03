#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI
import MetadataKit

/// The Home **hero** carousel: a cinematic, rotating spotlight at the top of
/// Home, functionally near-identical to the Apple TV app. Each slide reuses the
/// exact item-detail backdrop treatment (`HeroBackdropLayer`) plus the title
/// logo, metadata and Play / More Info / Watchlist actions.
///
/// Content is whatever the ``HeroCurator`` produced for the user's per-profile
/// ``HeroSettings`` (Continue Watching, Random, Watchlist and — once Seerr lands
/// — Featured). The carousel auto-advances on a timer and pages on the remote
/// per ``HeroCarouselFocus`` (right at the last button advances; left at the
/// first button steps back / escapes to the sidebar).
///
/// A background-video slot is threaded through `HeroBackdropLayer` for the
/// phased-in muted trailer; it renders nothing today.
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
    /// so Home can scroll the carousel back to full-screen and replay the
    /// enter transition. Not fired for interior button-to-button moves.
    var onFocusGained: () -> Void = {}
    /// Fired when the user presses **down** off the hero's buttons, so Home can
    /// scroll the Continue Watching row up into a centered reading position while
    /// the hero recedes to just its lower third — the Apple TV move. The native
    /// focus engine still moves focus down to the row itself.
    var onMoveDown: () -> Void = {}

    /// How far (in points) the backdrop is lifted UP relative to the content as the
    /// page scrolls down toward the Continue Watching row — the parallax. `HomeView`
    /// drives this from the scroll offset (clamped 0…~80). Only the backdrop layer
    /// receives it; the logo/overview/buttons scroll 1:1 with the page as normal.
    var backdropParallaxLift: CGFloat = 0

    /// The app-installed action handler — the SAME one the detail hero and the
    /// long-press context menu use — so the hero's Watchlist button is offered
    /// only when the item's provider supports it and its mutation fans out
    /// exactly like everywhere else.
    @Environment(\.mediaItemActionHandler) private var actionHandler
    @Environment(\.mediaItemActionContext) private var actionContext

    /// The index of the slide currently fronted.
    @State private var index: Int = 0
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
    private enum HeroFocus: Hashable { case row, leftGuard }
    /// Bumped on every manual page so the auto-advance `.task` restarts its dwell
    /// from the fresh slide instead of firing early.
    @State private var advanceToken = 0
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
    /// The Home hero backdrop is an **infinite horizontal strip** driven by a
    /// single, continuous, animatable position (`stripPosition`) — the item-space
    /// coordinate of the cell currently fronted in the viewport. Paging just
    /// animates this ONE value by ±1; every cell's parallax offset and reveal-wipe
    /// mask is a pure function of it (see `heroBackdropStack` /
    /// `cellContentOffset` / `revealMask`), so this is the *only* animated
    /// quantity. The cells' reveal slices are complementary, so there is never a
    /// z-order to get wrong, nor a completion-driven re-centre to race — the
    /// historical "new art appears behind / pops over the old / old lingers"
    /// wrong-order wipe is structurally impossible.
    ///
    /// `stripPosition`'s *state* value is always an exact integer (each page sets
    /// it to the neighbouring integer); SwiftUI interpolates the presentation, so
    /// the body always reads the settled target while the derived offsets/masks
    /// animate smoothly. A rapid second press just retargets the same animated
    /// value — no coalescing, no completion race. Because it is UNBOUNDED (it keeps
    /// counting up/down), the displayed item is `itemAt(Int(stripPosition))` with
    /// wrap-around modulo, and the end→start wrap is merely "position + 1" like any
    /// other page. Invariant at rest: `itemAt(Int(stripPosition)) == items[index]`.
    @State private var stripPosition: CGFloat = 0
    /// The contiguous (unbounded) integer cell indices currently mounted in the
    /// strip. At rest this is the 3 cells around the fronted slide
    /// (`center-1…center+1`). While paging it GROWS — via a union — to also cover
    /// the destination (and every cell in between across a rapid burst), so a cell
    /// that is mid-slide (even partly on screen) is NEVER pulled out from under the
    /// animation (the cause of a "pop"). It is pruned back to the 3-cell rest
    /// window only once the LATEST slide settles, and even then only ever removes
    /// far off-screen cells, so the prune is invisible.
    @State private var mountedRange: ClosedRange<Int> = -1...1
    /// Bumped on every page. The `withAnimation` completion that prunes
    /// `mountedRange` back to the rest window runs only if it still matches — so a
    /// superseded (interrupted) slide's completion, which still fires, can't prune
    /// cells the newer, still-running slide is relying on.
    @State private var pruneToken = 0
    /// The last directional move delivered to the hero's action row. Used to gate
    /// the recede: focus can leave the hero UP (to the tab bar) or LEFT (to the
    /// sidebar) as well as DOWN (to the Continue Watching row) — only a genuine
    /// DOWN should scroll the page. Recorded in `handleMove` before focus relocates.
    @State private var lastMoveDirection: MoveCommandDirection?
    /// Best resolved hero backdrop URL per item id. For episode/season slides
    /// this is the **series-level** hero art (correct show, high-res — matching
    /// the detail page), resolved via ``ArtworkRouter`` and preloaded for the
    /// current slide and its neighbours so a page never animates a placeholder.
    @State private var resolvedBackdrop: [String: URL] = [:]

    /// Pending "recede" scroll, scheduled when hero focus is lost and cancelled
    /// if focus returns within the same runloop. This decouples the recede from
    /// the Down *move command* (which a light Siri Remote trackpad graze fires
    /// spuriously, scrolling the page while focus never actually moved) and ties
    /// it instead to focus genuinely leaving the hero for the row below.
    @State private var recedeWork: DispatchWorkItem?

    @Environment(\.colorScheme) private var colorScheme

    private var current: MediaItem? {
        guard items.indices.contains(index) else { return items.first }
        return items[index]
    }

    /// The item shown by a strip cell at contiguous position `i`, wrapping around
    /// the carousel. `stripPosition` is unbounded, so this modulo maps a cell index
    /// (and its neighbours) back onto the real item list. Caller guarantees a
    /// non-empty carousel.
    private func itemAt(_ i: Int) -> MediaItem {
        let n = items.count
        let wrapped = ((i % n) + n) % n
        return items[wrapped]
    }

    /// Maps an unbounded contiguous cell index back onto the real `items` index it
    /// displays (wrap-around modulo). Caller guarantees a non-empty carousel.
    private func wrappedIndex(_ i: Int) -> Int {
        let n = items.count
        guard n > 0 else { return 0 }
        return ((i % n) + n) % n
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
    private static let contentBottomInset: CGFloat = 132

    // MARK: - Backdrop transition tuning

    /// Depth of the page parallax, as a fraction of the screen width. During a
    /// page the outgoing artwork drifts LEFT by at most this much and the
    /// incoming artwork sits this far to the RIGHT of its final spot — so
    /// **neither travels a full screen width.** The old image lingers, still
    /// mostly framed, instead of swiping fully off, and the new one is *revealed*
    /// (by the sweeping wipe below) rather than swiped in. `0` = a flat swipe.
    private static let parallaxDepth: CGFloat = 0.32

    /// Soft feather on the reveal seam (as a fraction of the screen width), so
    /// the wipe edge between the outgoing and incoming artwork is a smooth
    /// gradient rather than a hard line.
    private static let revealFeather: CGFloat = 0.06

    /// Duration of the backdrop wipe/parallax when a page is committed. The
    /// metadata fade-in (`beginTransition`) is timed to land just after this.
    private static let pageDuration: CGFloat = 0.5

    var body: some View {
        let height = Self.screenHeight * heroHeightFraction
        // The backdrop is a sibling *behind* the content in a real ZStack (not a
        // `.background`): SwiftUI's insertion/removal `.transition` does not fire
        // reliably inside `.background` on tvOS, which is what forced the old
        // runloop-timed offset dance. A plain ZStack layer animates the wipe
        // declaratively.
        ZStack(alignment: .bottomLeading) {
            heroBackdropStack(height: height)
            Group {
                if let item = current {
                    content(for: item)
                } else {
                    Color.clear
                }
            }
            .frame(maxWidth: .infinity, minHeight: height, alignment: .bottomLeading)
        }
        .frame(maxWidth: .infinity, minHeight: height, alignment: .bottomLeading)
        .opacity(heroVisible ? 1 : 0)
        .onAppear {
            reseatSlots()
            Task { await resolveArtwork(around: index) }
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
            // A set swap is not a page: front the (possibly relocated) current item
            // instantly with no wipe. Re-seat both backdrop slots to the current
            // item (the slots are permanently mounted now, not id-keyed) and bump
            // the token to cancel any pending fade-in.
            slideToken &+= 1
            metadataVisible = true
            reseatSlots()
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
        // Auto-advance: restart the dwell whenever the slide changes (manual page
        // or a previous auto-advance). This runs REGARDLESS of focus — focus lands
        // on the hero action row by default, so gating on `focus == nil` (as we
        // used to) froze the carousel the entire time the user was looking at it
        // and only cycled once they'd navigated away. The Apple TV hero keeps
        // cycling while focused; the buttons/metadata just track the new slide.
        .task(id: autoAdvanceKey) {
            guard settings.autoAdvance, items.count > 1 else { return }
            let seconds = UInt64(settings.autoAdvanceSeconds)
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            // Don't step on an in-flight manual page; that page bumped
            // `advanceToken`, which restarts (cancels) this dwell from the new
            // slide. Even if a slide is mid-animation, `page(...)` simply retargets
            // the same continuous position, so an auto-advance can never glitch it.
            guard !Task.isCancelled else { return }
            page(to: (index + 1) % items.count, keepButton: selectedButton, forward: true)
        }
    }

    /// The hero backdrop as an **infinite horizontal strip** of full-screen cells,
    /// rendered as an Apple-style *parallax reveal*. Every mounted cell is drawn at
    /// the viewport origin and positioned purely by a function of the single,
    /// continuous, animatable `stripPosition` — its signed distance from the
    /// fronted slot, `d = stripPosition - k`:
    ///
    /// - **Parallax offset** (`cellContentOffset`): an odd function of `d`, so the
    ///   outgoing image drifts LEFT and the incoming image sits to the RIGHT, each
    ///   by only a *fraction* of a screen width (`parallaxDepth`) — neither swipes
    ///   the full width. The old artwork lingers, still framed, rather than sliding
    ///   fully off; the new artwork barely shifts (it's *revealed*, not swiped in).
    /// - **Reveal wipe** (`revealMask`): each cell is masked to the slice of the
    ///   viewport nearest centre — the leading `(1 - d)` while it is the front /
    ///   outgoing (`d ≥ 0`), the trailing `(1 + d)` while it is upcoming (`d ≤ 0`).
    ///   These slices are exactly **complementary** (they meet at one feathered
    ///   seam that sweeps across), so the two images never overlap or gap and
    ///   **z-order is irrelevant** — the historical wrong-order / linger / pop wipe
    ///   is structurally impossible. At an integer `stripPosition` the fronted cell
    ///   (`d = 0`) owns the whole viewport and its neighbours own nothing, so the
    ///   rest state is always a single clean image.
    ///
    /// Because both the offset and the mask are pure functions of `stripPosition`,
    /// the entire transition is still driven by that ONE monotonic value: a page
    /// just animates it by ±1 and every cell follows. Cells are keyed by their
    /// unbounded integer index, so a page (and the end→start wrap) keeps the exact
    /// same, already-resolved view instances; only far off-screen cells are ever
    /// added or removed (see `mountedRange`), so structural churn is invisible.
    ///
    /// Cells pass `ignoresOverscan: false` so each stays exactly one screen wide;
    /// the overscan breakout is applied once here, to the whole viewport. The strip
    /// is lifted by `backdropParallaxLift` (the vertical parallax) so the artwork
    /// rises faster than the content as the page recedes.
    @ViewBuilder
    private func heroBackdropStack(height: CGFloat) -> some View {
        let w = Self.screenWidth
        if items.isEmpty {
            Color.clear.frame(width: w, height: height)
        } else {
            ZStack(alignment: .topLeading) {
                ForEach(Array(mountedRange), id: \.self) { k in
                    let d = stripPosition - CGFloat(k)
                    heroBackdrop(for: itemAt(k), height: height)
                        .frame(width: w, height: height)
                        .clipped()
                        // Parallax: shift the artwork content (a pure fn of `d`);
                        // `.offset` is render-only, so the mask below stays anchored
                        // to the viewport while the image slides underneath it.
                        .offset(x: cellContentOffset(d, width: w))
                        // Reveal wipe: mask to this cell's complementary slice of
                        // the viewport. Cells partition the screen exactly, so no
                        // overlap, no gap, and no z-order to get wrong.
                        .mask {
                            revealMask(d, width: w)
                                .frame(width: w, height: height)
                        }
                        // Cells are only ever inserted/removed while they own no
                        // visible slice (far off screen), so no transition is
                        // wanted — `.identity` keeps it instant under any ambient
                        // animation.
                        .transition(.identity)
                }
            }
            // One-screen viewport that clips the strip to just the fronted cell.
            .frame(width: w, height: height, alignment: .leading)
            .clipped()
            .frame(maxWidth: .infinity, alignment: .center)
            .offset(y: -backdropParallaxLift)
            .ignoresSafeArea(edges: [.top, .horizontal])
        }
    }

    /// Horizontal parallax offset (screen points) for a backdrop cell whose signed
    /// distance from the fronted slot is `d = stripPosition - k`. An **odd**
    /// function of `d`: the fronted cell (`d = 0`) is centred; a cell being left
    /// behind (`d > 0`) drifts LEFT and an upcoming cell (`d < 0`) sits to the
    /// RIGHT, each by at most `parallaxDepth` of a screen width while `|d| ≤ 1`,
    /// then continues off screen for `|d| > 1` (continuous at the boundary). Pure
    /// function of the single monotonic `stripPosition`, so it never introduces a
    /// second independent animated quantity.
    private func cellContentOffset(_ d: CGFloat, width w: CGFloat) -> CGFloat {
        let depth = Self.parallaxDepth
        if abs(d) <= 1 {
            return -depth * w * d
        }
        let sign: CGFloat = d > 0 ? 1 : -1
        return -sign * (depth * w + (abs(d) - 1) * w)
    }

    /// The reveal mask for a backdrop cell at distance `d = stripPosition - k`: the
    /// slice of the viewport (screen space) this cell "owns" during a page. A cell
    /// on the front / outgoing side (`d ≥ 0`) owns the **leading** `(1 - d)` of the
    /// viewport; an upcoming cell (`d ≤ 0`) owns the **trailing** `(1 + d)`. The two
    /// participating cells' slices are complementary — they meet at a single
    /// feathered seam that sweeps across as `stripPosition` animates — so the wipe
    /// has no overlap, no gap, and needs no z-order. At an integer position the
    /// fronted cell (`d = 0`) owns everything and its neighbours own nothing.
    @ViewBuilder
    private func revealMask(_ d: CGFloat, width w: CGFloat) -> some View {
        let feather = Self.revealFeather
        if d >= 0 {
            // Owns the LEADING (1 - d); seam runs down its trailing edge.
            let seam = max(0, min(1, 1 - d))
            LinearGradient(
                stops: [
                    .init(color: .white, location: 0),
                    .init(color: .white, location: max(0, seam - feather)),
                    .init(color: .clear, location: seam),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        } else {
            // Owns the TRAILING (1 + d); seam is at `-d` from the leading edge.
            let boundary = max(0, min(1, -d))
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .clear, location: boundary),
                    .init(color: .white, location: min(1, boundary + feather)),
                    .init(color: .white, location: 1)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
    }

    /// The dwell key: any change (slide index or a manual page bump) restarts the
    /// auto-advance timer from the current slide. Focus is deliberately NOT part of
    /// this — the carousel cycles whether or not the hero holds focus.
    private var autoAdvanceKey: String {
        "\(index)-\(advanceToken)"
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
            // Snap the metadata *hide* instantly (it now rides `page(...)`'s single
            // 0.42s wipe animation, which would otherwise fade the old text out
            // over the incoming art) while still allowing the delayed fade-IN.
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, PlozzTheme.Metrics.screenPadding)
        .padding(.trailing, PlozzTheme.Metrics.screenPadding)
        .padding(.leading, PlozzTheme.Metrics.heroLeadingPadding)
        // Lift the content column off the very bottom of the full-screen hero so
        // the logo / metadata / buttons / dots sit near the lower third and the
        // Continue Watching row can peek in just beneath the dots.
        .padding(.bottom, Self.contentBottomInset)
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
        HStack(spacing: 24) {
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
            // ── The single hero focus target: an always-opaque, invisible leaf
            // layered *over* the pills. Because `.overlay` is applied after the
            // pills' `.opacity`, it stays fully opaque and focusable even while the
            // pills fade to 0 — so focus (and therefore the scroll position) is
            // pinned throughout a page, while the buttons still disappear and
            // reappear. There is NO per-button `@FocusState`: Right/Down resolve in
            // `onMoveCommand` against our own `selectedButton` (always the true
            // pre-move value); Left is captured by the guard above. The hero pages
            // only on a real edge press, never because focus merely *landed* on an
            // edge button. ──
            .overlay {
                Color.clear
                    .contentShape(Rectangle())
                    .focusable(true)
                    .focused($focus, equals: .row)
                    // Initial Home focus lands on the hero (not a CW card).
                    .prefersDefaultFocus(true, in: focusScope)
                    .onMoveCommand { handleMove($0) }
                    // Remote **Select** activates the selected pill.
                    .onTapGesture { activateSelected() }
                    // Play/Pause is a shortcut straight to playback.
                    .onPlayPauseCommand { if let item = current { onPlay(item) } }
                    .accessibilityElement(children: .ignore)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel(accessibilityLabel(for: item))
                    .accessibilityAction { activateSelected() }
                    .modifier(HeroActionAccessibility(actions: a11yActions))
            }
            // Pin a *constant* identity so focus is retained across a page (item
            // id changes). Never key this on the item id — that would drop focus.
            .id(Self.actionRowFocusID)
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Always-on (never toggled): a lone focusable under a *conditional* focus
        // section churned structure on every interior move on the first slide,
        // which jostled the scroll position. Constant confinement keeps Down going
        // to Continue Watching and Right paging cleanly.
        .focusSection()
        .onChange(of: focus) { old, new in
            switch new {
            case .leftGuard:
                // The engine parked focus on the guard because Left was pressed.
                // Resolve it and bounce straight back to the row.
                handleLeft()
            case .row:
                // Focus is (back) on the hero: cancel any pending recede — a
                // transient focus blip must never scroll the page.
                recedeWork?.cancel()
                recedeWork = nil
                // At rest on the row, clear the recorded move so a stale direction
                // from an earlier press can't leak into the next focus-loss gate.
                lastMoveDirection = nil
                // Focus arriving into the hero from *outside* (a row below / the
                // tab bar): snap back to full-screen. We do NOT recede on focus
                // *loss* — focus can drop transiently and must never scroll.
                if old == nil {
                    if let item = current {
                        selectedButton = min(selectedButton, max(0, buttons(for: item).count - 1))
                    }
                    onFocusGained()
                }
            case .none:
                // Hero lost focus. Only a genuine DOWN move (to the Continue
                // Watching row) should recede/scroll the page. Focus can also leave
                // UP (to the tab bar) or LEFT (to the sidebar) — those must NOT
                // scroll (the reported bug: landing in the top/side nav still
                // shifted the page down). A light graze never changes focus at all,
                // so this case does not even run for a graze. Gate on the last move.
                recedeWork?.cancel()
                recedeWork = nil
                guard lastMoveDirection == .down else { break }
                // Confirm on the next runloop: a transient blip returns to `.row`
                // and cancels this; a real Down keeps focus gone, so it fires.
                let work = DispatchWorkItem {
                    if focus == nil { onMoveDown() }
                }
                recedeWork = work
                DispatchQueue.main.async(execute: work)
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

    /// Applies the tested `HeroCarouselFocus` reducer to a Right/Down press on the
    /// pill row. (Left is never delivered here — it is captured by the invisible
    /// left guard and routed through `handleLeft()`.) Resolves the *live* slide
    /// via `current` and clamps `selectedButton` to the live button count FIRST —
    /// so a rapid repeat that arrives before SwiftUI reinstalls the row's closures
    /// can't evaluate the edge against the previous slide's button count and
    /// false-page. `selectedButton` is our own state, so it is always the true
    /// PRE-move value. Interior moves update `selectedButton` ourselves (the engine
    /// is not involved); only `.advance` pages.
    private func handleMove(_ direction: MoveCommandDirection) {
        // Record the direction BEFORE focus can relocate, so the recede (driven by
        // focus leaving the hero) can tell a genuine DOWN-to-row move from an UP
        // (to the tab bar) or LEFT (to the sidebar) escape — only DOWN should
        // scroll the page. A light trackpad graze fires a phantom `.down` here but
        // never actually moves focus, so it still can't recede (see `.none` below).
        lastMoveDirection = direction
        guard let item = current else { return }
        let buttonCount = buttons(for: item).count
        selectedButton = min(selectedButton, max(0, buttonCount - 1))
        switch direction {
        case .down:
            // Do NOT recede here. A light trackpad graze makes tvOS fire a phantom
            // `.down` move command even when focus never relocates, which used to
            // scroll the page down while focus stayed pinned (the reported bug).
            // The recede is now driven purely by focus actually leaving the hero
            // for the row below — see `.onChange(of: focus)`. On a real Down the
            // focus engine relocates focus (dropping hero `focus` to nil) and that
            // change triggers the recede; a graze leaves focus untouched, so
            // nothing scrolls.
            break
        case .right:
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
                // We own the selection — move it ourselves. No focus engine round
                // trip, so this is instantaneous and can never race.
                selectedButton = newIndex
            case let .advance(toItem, keepButton):
                page(to: toItem, keepButton: keepButton, forward: true)
            case .escape, .blocked:
                break
            }
        default:
            // Left is handled by the guard; Up is left to the system.
            break
        }
    }

    /// Resolves a Left press captured by the invisible left guard, then bounces
    /// focus straight back to the pill row so the guard never visibly holds it.
    /// Interior moves adjust `selectedButton`; `.advance` pages backward. The one
    /// `.escape` case (first item, left-most button, sidebar) can't reach here —
    /// the guard is non-focusable there, so Left falls through to the sidebar.
    private func handleLeft() {
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

    /// Fires the currently-selected pill's action (remote Select / Play-Pause).
    /// Resolves the live slide and clamps the index defensively so a stale
    /// selection can never dispatch the wrong (or an out-of-range) action.
    private func activateSelected() {
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

    /// Fronts `toItem` with a directional slide and restarts the auto-advance
    /// dwell. Callers only ever page by ±1 (Right/Left/chevron/auto-advance), so
    /// `toItem` is always the current slide's neighbour — the strip simply animates
    /// its single continuous position ONE integer in `forward`'s direction. `index`
    /// (the logical/wrapped slide) and the selection update immediately; the strip
    /// catches up smoothly. A rapid second press reads the already-advanced target
    /// and just retargets the same animated position — there is no coalescing, no
    /// completion race, and no re-centre, so a slide can never be interrupted into
    /// a wrong-order/pop/linger artifact.
    private func page(to toItem: Int, keepButton: Int, forward isForward: Bool) {
        guard items.indices.contains(toItem), toItem != index else { return }
        let step = isForward ? 1 : -1
        // The strip's *state* position is always an exact integer; step to the
        // neighbouring one. A rapid press reads the target the previous press
        // already set here, so successive presses accumulate and the offset just
        // keeps sliding without ever snapping back.
        let currentCenter = Int(stripPosition.rounded())
        let targetCenter = currentCenter + step
        // Grow the mounted window (union with what's already mounted) so it always
        // covers the destination and everything between the current position and
        // it — a mid-slide cell is thus never removed under the running animation
        // (which is what caused a "pop"). Pruned back to the rest window on settle.
        mountedRange = min(mountedRange.lowerBound, targetCenter - 1)...max(mountedRange.upperBound, targetCenter + 1)
        beginTransition()
        pruneToken &+= 1
        let token = pruneToken
        // Logical slide + selection update immediately (metadata resolves the new
        // show and the buttons track it); the strip animates to the new centre.
        // Metadata is hidden instantly and faded back in by `beginTransition()`
        // once the wipe has landed.
        index = toItem
        advanceToken &+= 1
        metadataVisible = false
        selectedButton = min(keepButton, max(0, buttons(for: items[toItem]).count - 1))
        withAnimation(.easeInOut(duration: Self.pageDuration)) {
            stripPosition = CGFloat(targetCenter)
        } completion: {
            // Only the LATEST slide prunes: an interrupted slide's completion still
            // fires, but a newer page bumped `pruneToken`, so it leaves the grown
            // window (still in use by the running slide) untouched. When it does
            // run, the strip is settled, so it only trims far off-screen cells.
            guard token == pruneToken else { return }
            let c = Int(stripPosition.rounded())
            mountedRange = (c - 1)...(c + 1)
        }
        Task { await resolveArtwork(around: toItem) }
    }

    /// Re-seats the strip on the current logical slide with NO animation, used on
    /// first appearance and on a curated-set swap. Restores the resting invariant
    /// `itemAt(Int(stripPosition)) == items[index]` and the 3-cell rest window in
    /// one `disablesAnimations` transaction — an instant, invisible re-centre. When
    /// the fronted item survived a set swap unchanged it keeps the SAME cell slot
    /// (and so its already-loaded art), rather than jumping and reloading.
    private func reseatSlots() {
        guard !items.isEmpty else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            // Pick the strip position congruent to `index` (mod count) that is
            // nearest where we already are, so an unchanged fronted item keeps its
            // exact slot and its resolved backdrop instead of reloading.
            let currentCenter = Int(stripPosition.rounded())
            let center = currentCenter + (index - wrappedIndex(currentCenter))
            stripPosition = CGFloat(center)
            mountedRange = (center - 1)...(center + 1)
        }
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

    /// Schedules the metadata fade-BACK-IN for a page. The metadata is hidden
    /// *instantly* inside `page(...)`'s single `withAnimation` (stripped locally so
    /// it snaps rather than fades — see `content(for:)`/`actionRow(for:)`), NOT via
    /// a separate `withTransaction(disablesAnimations:)` here: a competing
    /// transaction in the same turn let the backdrop's insertion skip its
    /// animation. This only starts the delayed fade-in, just past the wipe
    /// duration (`pageDuration`) and guarded by ``slideToken`` so a rapid second
    /// page cancels the first page's pending fade-in.
    private func beginTransition() {
        slideToken &+= 1
        let token = slideToken
        // Hold the metadata out until the wipe has essentially landed, then fade
        // the new slide's text in so it never reads over the mid-wipe artwork.
        let delay = UInt64(Double(Self.pageDuration) * 0.92 * 1_000_000_000)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: delay)
            guard slideToken == token else { return }
            withAnimation(.easeInOut(duration: 0.3)) { metadataVisible = true }
        }
    }

    // MARK: - Paging dots

    @ViewBuilder
    private var pagingDots: some View {
        if items.count > 1 {
            HStack(spacing: 10) {
                ForEach(items.indices, id: \.self) { i in
                    Circle()
                        .fill(i == index ? Color.primary : Color.primary.opacity(0.28))
                        .frame(width: 8, height: 8)
                        .animation(.easeInOut(duration: 0.2), value: index)
                }
            }
            .padding(.top, 10)
            .accessibilityHidden(true)
        }
    }

    // MARK: - Backdrop

    @ViewBuilder
    private func heroBackdrop(for item: MediaItem, height: CGFloat) -> some View {
        HeroBackdropLayer(
            urls: primaryBackdropURLs(for: item),
            asyncFallbackURL: backdropFallback(for: item),
            placeholderPosterURL: item.posterURL,
            height: height,
            scrimTone: scrimTone,
            // Full-screen hero: keep the artwork opaque far lower than the detail
            // page (which melts at 0.33) and only feather the very bottom into the
            // Continue Watching panel.
            dissolveStart: 0.82,
            // The filmstrip tiles several of these side by side, so each cell must
            // stay exactly one screen wide; the overscan breakout is applied once at
            // the strip's viewport (see `heroBackdropStack`), not per cell.
            ignoresOverscan: false
        )
    }

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
