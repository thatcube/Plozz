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
    /// The Home hero backdrop is a **single horizontal filmstrip** — an `HStack` of
    /// three cells `[itemAt(centerIndex-1), itemAt(centerIndex), itemAt(centerIndex+1)]`
    /// that moves as ONE unit via a single animatable offset (`slidePosition`).
    /// There is only ever one thing animating, so the old two-independent-layer
    /// design (where SwiftUI could animate one side and drop the other, producing
    /// the intermittent "new art appears behind/over the old" wrong-order wipe) is
    /// structurally impossible now.
    ///
    /// The key to the transition's robustness is *when* the window moves. The
    /// window shift (`centerIndex ± 1`) — the ONLY structural change to the
    /// `ForEach`, which swaps one far, off-screen cell in and one out — is committed
    /// **up front, before the visible animation begins**, inside a
    /// `disablesAnimations` transaction. `slidePosition` is simultaneously
    /// pre-loaded to the opposite edge (∓1) so the strip still displays the
    /// *outgoing* slide at that instant (no visible jump). The visible slide is then
    /// a pure `slidePosition → 0` animation during which the `ForEach` is completely
    /// static. There is NO completion handler and NO settle re-window, so SwiftUI
    /// can never decompose the strip's motion into a per-cell fade/move (the old
    /// wrong-order wipe) — a structural change never coincides with an animation.
    /// At rest `slidePosition` is always 0 and `centerIndex` is always the fronted
    /// slide.
    ///
    /// `centerIndex` is an UNBOUNDED contiguous counter (it just keeps incrementing
    /// forward / decrementing backward); the displayed item is `itemAt(centerIndex)`
    /// with wrap-around modulo. Keeping it contiguous (rather than wrapping it to
    /// 0…count-1) is what preserves cell identity across the end→start wrap: the
    /// `ForEach` ids `[c-1, c, c+1]` always overlap by two with the next window, so
    /// the cell sliding to centre is the SAME view instance (art already resolved)
    /// even when the *item* wrapped. The invariant `itemAt(centerIndex) == items[index]`
    /// holds at rest.
    @State private var centerIndex = 0
    /// The filmstrip offset in screen-width units. 0 at rest (centre cell shown). A
    /// page commits `centerIndex` up front and pre-loads this to -1 (forward) or +1
    /// (backward) — which, with the shifted window, still shows the *outgoing* slide
    /// — then animates it back to 0, sliding the incoming slide to centre.
    @State private var slidePosition: CGFloat = 0
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

    /// The item shown by a filmstrip cell at contiguous position `i`, wrapping
    /// around the carousel. `centerIndex` is unbounded, so this modulo maps it (and
    /// its ±1 neighbours) back onto the real item list. Caller guarantees non-empty.
    private func itemAt(_ i: Int) -> MediaItem {
        let n = items.count
        let wrapped = ((i % n) + n) % n
        return items[wrapped]
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
            // `advanceToken`, which restarts this dwell from the new slide.
            guard !Task.isCancelled, slidePosition == 0 else { return }
            page(to: (index + 1) % items.count, keepButton: selectedButton, forward: true)
        }
    }

    /// The hero backdrop as a **single horizontal filmstrip**: an `HStack` of three
    /// full-screen-width cells — `itemAt(centerIndex-1)`, `itemAt(centerIndex)`,
    /// `itemAt(centerIndex+1)` — clipped to a one-screen viewport and slid by ONE
    /// animatable offset (`slidePosition`). Because the whole strip is a single
    /// view that moves as a unit, there is never a second, independent animation
    /// that SwiftUI can drop — the root cause of every prior wrong-order wipe (two
    /// layers, only one animating). The centred cell's content never changes during
    /// a slide; the window only re-windows at settle (`disablesAnimations`), and the
    /// `ForEach` ids overlap by two across windows so the cell sliding to centre is
    /// the same, already-resolved view instance (even across the end→start wrap).
    ///
    /// Cells pass `ignoresOverscan: false` so each stays exactly one screen wide and
    /// the strip tiles correctly; the overscan breakout is applied once here, to the
    /// whole viewport. The strip is lifted by `backdropParallaxLift` (the parallax)
    /// so the artwork rises faster than the content as the page recedes.
    @ViewBuilder
    private func heroBackdropStack(height: CGFloat) -> some View {
        let w = Self.screenWidth
        if items.isEmpty {
            Color.clear.frame(width: w, height: height)
        } else {
            HStack(spacing: 0) {
                ForEach([centerIndex - 1, centerIndex, centerIndex + 1], id: \.self) { i in
                    heroBackdrop(for: itemAt(i), height: height)
                        .frame(width: w, height: height)
                        .clipped()
                }
            }
            .frame(width: w * 3, height: height, alignment: .leading)
            // Slide the whole 3-wide strip as one unit. Rest offset is -w (centre
            // cell in the viewport). A page pre-loads `slidePosition` to -1 (forward)
            // or +1 (backward) with the window already shifted — still showing the
            // outgoing slide — then animates it to 0 to bring the incoming slide to
            // centre.
            .offset(x: -w * (1 + slidePosition))
            // One-screen viewport that clips the strip to just the centred cell.
            .frame(width: w, height: height, alignment: .leading)
            .clipped()
            .frame(maxWidth: .infinity, alignment: .center)
            .offset(y: -backdropParallaxLift)
            .ignoresSafeArea(edges: [.top, .horizontal])
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

    /// Fronts `toItem` with a directional filmstrip slide and restarts the
    /// auto-advance dwell. Callers only ever page by ±1 (Right/Left/chevron/
    /// auto-advance), so `toItem` is always the current slide's neighbour.
    ///
    /// The transition is deliberately completion-handler-free. The window shift
    /// (`centerIndex ± step`) — the ONLY structural `ForEach` change — is committed
    /// **up front**, in a `disablesAnimations` transaction, together with
    /// pre-loading `slidePosition` to the opposite edge (∓step). With the shifted
    /// window that edge value still displays the *outgoing* slide, so there is no
    /// visible jump. We then animate `slidePosition → 0`, a pure offset slide during
    /// which the `ForEach` is static — so SwiftUI can never split the motion into a
    /// per-cell fade/move (the wrong-order wipe). `index` (the logical/wrapped
    /// slide) updates immediately so rapid presses compute the right next target and
    /// the metadata resolves the new show.
    private func page(to toItem: Int, keepButton: Int, forward isForward: Bool) {
        guard items.indices.contains(toItem), toItem != index else { return }
        let step = isForward ? 1 : -1

        // Land any in-flight slide instantly. `centerIndex` is always committed up
        // front (below), so the in-flight slide's destination cell already *is*
        // `centerIndex`; snapping `slidePosition` to 0 lands it with no window
        // change and no structural churn — just the offset settling to rest.
        if slidePosition != 0 {
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { slidePosition = 0 }
        }

        beginTransition()

        // Commit the window shift UP FRONT (never during the visible animation) and
        // pre-load `slidePosition` to the opposite edge so the strip still shows the
        // OUTGOING slide at animation start — no jump. This is the sole structural
        // ForEach change (one far, off-screen cell swaps in/out) and it happens here
        // inside a `disablesAnimations` transaction, so it can't decompose into a
        // per-cell fade/move. During the slide below the ForEach is completely
        // static.
        var pre = Transaction(); pre.disablesAnimations = true
        withTransaction(pre) {
            centerIndex += step
            slidePosition = CGFloat(-step)
        }

        // Logical slide + selection update immediately; the strip's centred art is
        // driven by `centerIndex`, which is already correct.
        index = toItem
        advanceToken &+= 1
        metadataVisible = false
        selectedButton = min(keepButton, max(0, buttons(for: items[toItem]).count - 1))

        // The visible slide: a pure offset animation to rest. No completion handler,
        // no settle re-window — at rest `slidePosition` is always 0 and
        // `centerIndex` is always the fronted slide.
        withAnimation(.easeInOut(duration: 0.42)) {
            slidePosition = 0
        }

        Task { await resolveArtwork(around: toItem) }
    }

    /// Re-seats the filmstrip on the current logical slide with NO animation, used
    /// on first appearance and on a curated-set swap. Restores the resting invariant
    /// `itemAt(centerIndex) == items[index]` and zeroes the offset in one
    /// `disablesAnimations` transaction, so it's an instant, invisible re-centre.
    private func reseatSlots() {
        guard !items.isEmpty else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            centerIndex = index
            slidePosition = 0
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
    /// animation. This only starts the delayed fade-in, past the wipe duration
    /// (0.42s) and guarded by ``slideToken`` so a rapid second page cancels the
    /// first page's pending fade-in.
    private func beginTransition() {
        slideToken &+= 1
        let token = slideToken
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 460_000_000)
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
