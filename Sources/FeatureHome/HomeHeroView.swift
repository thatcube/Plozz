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
    /// The direction of the in-flight page, driving the backdrop wipe: forward
    /// slides the new artwork in from the trailing edge (old exits leading);
    /// backward reverses it. Set synchronously just before `index` so the
    /// declarative `.transition` reads the right edges.
    @State private var forward = true
    /// Best resolved hero backdrop URL per item id. For episode/season slides
    /// this is the **series-level** hero art (correct show, high-res — matching
    /// the detail page), resolved via ``ArtworkRouter`` and preloaded for the
    /// current slide and its neighbours so a page never animates a placeholder.
    @State private var resolvedBackdrop: [String: URL] = [:]

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
            metadataVisible = true
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
        // or a previous auto-advance) and pause while the hero holds focus.
        .task(id: autoAdvanceKey) {
            guard settings.autoAdvance, items.count > 1, focus == nil else { return }
            let seconds = UInt64(settings.autoAdvanceSeconds)
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard !Task.isCancelled, focus == nil else { return }
            page(to: (index + 1) % items.count, keepButton: selectedButton, forward: true)
        }
    }

    /// The hero backdrop, keyed by the fronted item's id so a page is a real
    /// identity change: SwiftUI removes the old layer and inserts the new one,
    /// driving the directional wipe declaratively (no runloop-timed offset dance,
    /// which CoreAnimation coalesced to a pop-in). Constrained to the screen width
    /// and clipped so the full-bleed art can't inflate the layout width and the
    /// sliding layers never bleed horizontally.
    @ViewBuilder
    private func heroBackdropStack(height: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            if let item = current {
                heroBackdrop(for: item, height: height)
                    .id(item.id)
                    .transition(slideTransition)
            }
        }
        .frame(width: Self.screenWidth, height: height, alignment: .bottom)
        .frame(maxWidth: .infinity, alignment: .center)
        .clipped()
        .animation(.easeInOut(duration: 0.42), value: current?.id)
    }

    /// The directional wipe: the incoming backdrop slides in from the trailing
    /// edge (forward) or leading edge (backward) while the outgoing exits the
    /// opposite side — the Apple TV "push".
    private var slideTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: forward ? .trailing : .leading),
            removal: .move(edge: forward ? .leading : .trailing)
        )
    }

    /// The dwell key: any change (slide index, focus state, or a manual page
    /// bump) restarts the auto-advance timer from the current slide.
    private var autoAdvanceKey: String {
        "\(index)-\(focus != nil)-\(advanceToken)"
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
            // Everything that describes *this show*. Hidden instantly on a page and
            // faded back in once the new backdrop has wiped into place, so the old
            // title/overview/buttons never sit over the incoming artwork.
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

                // Zero-height recede target: sits just above the buttons so a
                // down-press lifts the logo/title off the top of the screen.
                Color.clear
                    .frame(height: 0)
                    .id(Self.recedeAnchorID)

                actionRow(for: item)
            }
            .opacity(metadataVisible ? 1 : 0)

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
            // which a lone focusable can't prevent. It is focusable everywhere
            // EXCEPT the one escape spot (first item, left-most button, sidebar
            // nav): there it steps aside so Left falls through and opens the side
            // navigation, exactly as on the Apple TV app.
            Color.clear
                .frame(width: 1, height: 1)
                .focusable(!allowsSidebarEscape)
                .focused($focus, equals: .leftGuard)
                .accessibilityHidden(true)

            HStack(spacing: 24) {
                ForEach(Array(itemButtons.enumerated()), id: \.element) { offset, button in
                    heroButtonVisual(button, for: item, selected: focus != nil && selectedButton == offset)
                }
            }
            .contentShape(Rectangle())
            // ── The pill row is ONE focus target. There is NO per-button
            // `@FocusState`, so the focus engine can never move focus between pills
            // behind our back: Right/Down are resolved in `onMoveCommand` against
            // our own `selectedButton` (always the true pre-move value); Left is
            // captured by the guard above. The hero pages only on a real edge
            // press, never merely because focus *landed* on an edge button. ──
            .focusable(true)
            .focused($focus, equals: .row)
            // Initial Home focus lands on the hero (not a Continue Watching card).
            .prefersDefaultFocus(true, in: focusScope)
            .onMoveCommand { handleMove($0) }
            // Remote **Select** on the focused row activates the selected pill.
            .onTapGesture { activateSelected() }
            // Play/Pause is a convenient shortcut straight to playback.
            .onPlayPauseCommand { if let item = current { onPlay(item) } }
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(accessibilityLabel(for: item))
            .accessibilityAction { activateSelected() }
            .modifier(HeroActionAccessibility(actions: a11yActions))
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
        guard let item = current else { return }
        let buttonCount = buttons(for: item).count
        selectedButton = min(selectedButton, max(0, buttonCount - 1))
        switch direction {
        case .down:
            onMoveDown()
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
        if prominent {
            shape.fill(Color.accentColor)
        } else if #available(tvOS 26.0, *) {
            shape.fill(.clear).glassEffect(.regular, in: shape)
        } else {
            shape.fill(.ultraThinMaterial)
        }
    }

    /// Fronts `toItem` with a directional wipe, restarts the auto-advance dwell,
    /// and (only when the hero holds focus) re-pins focus on `keepButton` for the
    /// destination slide. The wipe itself is declarative: changing `index` swaps
    /// the id-keyed backdrop, and `heroBackdropStack`'s `.animation(value:)` runs
    /// the `.move` transition. `forward` selects the wipe edges.
    /// Fronts `toItem` with a directional wipe and restarts the auto-advance
    /// dwell. The wipe itself is declarative: changing `index` swaps the id-keyed
    /// backdrop, and `heroBackdropStack`'s `.animation(value:)` runs the `.move`
    /// transition. `forward` selects the wipe edges.
    private func page(to toItem: Int, keepButton: Int, forward isForward: Bool) {
        guard items.indices.contains(toItem), toItem != index else { return }
        beginTransition()
        // Set direction before index so the transition reads the right edges;
        // both land in one render pass.
        forward = isForward
        index = toItem
        advanceToken &+= 1

        // Keep the logical selection on the destination, clamped to its button
        // count. Pure `@State` on a *stable* focus target (the row's identity
        // never changes across a page), so focus stays put and only the highlight
        // moves — no fragile deferred `@FocusState` re-pin, no dropped focus.
        selectedButton = min(keepButton, max(0, buttons(for: items[toItem]).count - 1))
        Task { await resolveArtwork(around: toItem) }
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

    /// Starts a slide change: hides the current slide's metadata *immediately*
    /// (no animation) so the old title/overview/buttons never sit over the
    /// incoming artwork, then fades it back in once the backdrop wipe has landed.
    /// The fade-in is delayed past the wipe duration (0.42s) and anchored to the
    /// same start, and guarded by ``slideToken`` so a rapid second page cancels
    /// the first page's pending fade-in.
    private func beginTransition() {
        slideToken &+= 1
        let token = slideToken
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { metadataVisible = false }
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
            dissolveStart: 0.82
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
