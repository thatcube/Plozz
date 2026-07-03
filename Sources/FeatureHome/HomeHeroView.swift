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
    /// The action button holding focus (`0` = Play). Bound to the real buttons so
    /// the paging reducer knows which edge we're at.
    @FocusState private var focusedButton: Int?
    /// Whether the hero currently holds focus — pauses auto-advance so the user
    /// is never yanked mid-read while interacting.
    @State private var hasFocus = false
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
    /// The slide leaving the screen during a page, held as a second backdrop
    /// layer so the new artwork can visibly slide *over* it. `nil` when no page
    /// is in flight. Rendered behind `current` and cleared once the wipe lands.
    @State private var outgoing: MediaItem?
    /// Horizontal offset of the incoming (fronted) backdrop: starts one screen
    /// width off (leading or trailing per direction) and animates to 0 so the
    /// new artwork slides into place.
    @State private var incomingOffset: CGFloat = 0
    /// Horizontal offset of the outgoing backdrop: animates a short distance the
    /// opposite way (with a fade) so it reads as receding behind the new image.
    @State private var outgoingOffset: CGFloat = 0
    /// Opacity of the outgoing backdrop through the wipe.
    @State private var outgoingOpacity: Double = 1
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
        Group {
            if let item = current {
                content(for: item)
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, minHeight: height, alignment: .bottomLeading)
        .background(alignment: .bottom) {
            // Two backdrop layers so a page slides the new artwork *over* the
            // old one. Manual `.offset` animation (rather than a `.transition`)
            // because the hero backdrop must live in a `.background` to avoid the
            // over-wide full-bleed inflating the layout width — and `.background`
            // does not animate insertion transitions. The outgoing layer is drawn
            // first (behind); the incoming (`current`) on top.
            ZStack(alignment: .bottom) {
                if let outgoing {
                    heroBackdrop(for: outgoing, height: height)
                        .offset(x: outgoingOffset)
                        .opacity(outgoingOpacity)
                }
                if let item = current {
                    heroBackdrop(for: item, height: height)
                        .offset(x: incomingOffset)
                }
            }
        }
        .opacity(heroVisible ? 1 : 0)
        .onAppear {
            Task { await resolveArtwork(around: index) }
            guard !heroVisible else { return }
            withAnimation(.easeInOut(duration: 0.35)) { heroVisible = true }
        }
        // Keep the fronted slide valid if the curated set shrinks under us.
        .onChange(of: items.count) { _, count in
            if index >= count { index = max(0, count - 1) }
        }
        // Auto-advance: restart the dwell whenever the slide changes (manual page
        // or a previous auto-advance) and pause while the hero holds focus.
        .task(id: autoAdvanceKey) {
            guard settings.autoAdvance, items.count > 1, !hasFocus else { return }
            let seconds = UInt64(settings.autoAdvanceSeconds)
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            advance(to: (index + 1) % items.count, keepButton: focusedButton ?? 0, forward: true)
        }
    }

    /// The dwell key: any change (slide index, focus state, or a manual page
    /// bump) restarts the auto-advance timer from the current slide.
    private var autoAdvanceKey: String {
        "\(index)-\(hasFocus)-\(advanceToken)"
    }

    // MARK: - Content column

    /// Stable scroll anchor on the metadata block. Pressing down scrolls this to
    /// the top of the viewport: the show's logo/meta/overview/buttons land in the
    /// upper region with the lower portion of the backdrop behind them, and the
    /// Continue Watching row sits below — the Apple TV "recede" position. A
    /// constant id (independent of the slide) keeps it a fixed scroll target.
    static let metadataAnchorID = "home-hero-metadata"

    /// Scroll anchor just above the action row. Pressing **down** off the hero
    /// scrolls this near the top of the viewport, so the show's logo/title lift
    /// off the top and the overview/buttons/dots settle into the upper region
    /// with the Continue Watching row centered below — the Apple TV "recede".
    static let recedeAnchorID = "home-hero-recede"

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
            .id(Self.metadataAnchorID)

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
        // A backward-paging sentinel sits just left of Play — EXCEPT on the first
        // item in Sidebar mode, where Left must instead escape to open the side
        // navigation (per `HeroCarouselFocus`). Its width+spacing is cancelled by
        // negative leading padding below so the buttons never visibly shift.
        let showLeftSentinel = items.count > 1 && !(index == 0 && navigationStyle == .sidebar)
        HStack(spacing: 24) {
            // Invisible left-edge sentinel (backward). Pressing Left while on Play
            // moves the focus engine onto this, which pages the carousel *backward*
            // and returns focus to Play — a deterministic edge signal with no
            // `.onMoveCommand` timing guesswork. Absent when Left should open the
            // sidebar, so that case falls through to the native focus engine.
            if showLeftSentinel {
                Button {} label: { Color.clear.frame(width: 2, height: 44) }
                    .buttonStyle(.plain)
                    .focused($focusedButton, equals: Self.backSentinelOffset)
                    .accessibilityHidden(true)
            }
            ForEach(Array(itemButtons.enumerated()), id: \.element) { offset, button in
                actionButton(button, at: offset, for: item)
            }
            // Invisible right-edge sentinel (forward). Pressing Right while on the
            // last real button moves focus onto this, paging forward and returning
            // focus to the new slide's chevron. Trailing empty space absorbs its
            // width, so it never shifts the leading-aligned buttons.
            if items.count > 1 {
                Button {} label: { Color.clear.frame(width: 2, height: 44) }
                    .buttonStyle(.plain)
                    .focused($focusedButton, equals: Self.sentinelOffset)
                    .accessibilityHidden(true)
            }
        }
        // Cancel the left sentinel's width (2) + its HStack spacing (24) so Play
        // stays put whether or not the sentinel is present — no visible shift.
        .padding(.leading, showLeftSentinel ? -26 : 0)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
        // Only Down is intercepted here (recede to Continue Watching); left/right
        // are left entirely to the native focus engine, and paging is driven by
        // the invisible edge sentinels via `onChange`. Acting on left/right here
        // was what made *every* press transition — rebuilding the buttons and
        // dropping focus to the row.
        .onMoveCommand { direction in
            if direction == .down { onMoveDown() }
        }
        .onChange(of: focusedButton) { old, new in
            // Focus landed on an edge sentinel: page. `advanceForward`/`Backward`
            // re-pin focus onto a real button of the destination slide, so focus
            // never rests on an (invisible) sentinel.
            if new == Self.sentinelOffset {
                advanceForward()
                return
            }
            if new == Self.backSentinelOffset {
                advanceBackward()
                return
            }
            hasFocus = new != nil
            // Focus arriving from *outside* (a row below, the tab bar): snap the
            // hero back to full-screen. We deliberately do NOT recede on focus
            // *loss* — focus can drop to nil transiently (a button re-rendering,
            // opening the side navigation menu) and that must never scroll the
            // page. Receding is driven only by an intentional Down press.
            if new != nil, old == nil { onFocusGained() }
        }
    }

    /// Focus tags for the invisible edge-paging sentinels — values that can never
    /// collide with a real button offset.
    private static let sentinelOffset = 1_000_000
    private static let backSentinelOffset = 1_000_001

    @ViewBuilder
    private func actionButton(_ button: HeroButton, at offset: Int, for item: MediaItem) -> some View {
        switch button {
        case .play:
            Button {
                onPlay(item)
            } label: {
                Label(item.resumePosition != nil ? "Resume" : "Play", systemImage: "play.fill")
            }
            .modifier(HeroActionButtonStyle(prominent: true))
            .focused($focusedButton, equals: offset)
            // Initial Home focus lands here (not a Continue Watching card).
            .prefersDefaultFocus(true, in: focusScope)
        case .moreInfo:
            Button {
                onSelect(item)
            } label: {
                Label("More Info", systemImage: "info.circle")
            }
            .modifier(HeroActionButtonStyle(prominent: false))
            .focused($focusedButton, equals: offset)
        case .watchlist:
            let target = watchlistTarget(for: item)
            Button {
                if let action = watchlistAction(for: item) {
                    actionHandler?.perform(action, on: target, context: actionContext)
                    // Flip the button instantly; the loaded row can lag (an added
                    // series from an episode slide isn't an existing card).
                    let key = Self.watchlistKey(accountID: target.sourceAccountID, itemID: target.id)
                    watchlistOverrides[key] = (action == .addToWatchlist)
                }
            } label: {
                Image(systemName: target.isFavorite ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 30))
                    .foregroundStyle(target.isFavorite ? Color.accentColor : Color.primary)
                    .symbolEffect(.bounce, value: target.isFavorite)
                    .frame(width: 38, height: 38)
            }
            .modifier(HeroActionButtonStyle(prominent: false))
            .focused($focusedButton, equals: offset)
            .accessibilityLabel(target.isFavorite ? "Remove from Watchlist" : "Add to Watchlist")
        case .next:
            Button {
                advanceForward()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 30, weight: .semibold))
                    .frame(width: 38, height: 38)
            }
            .modifier(HeroActionButtonStyle(prominent: false))
            .focused($focusedButton, equals: offset)
            .accessibilityLabel("Next")
        }
    }

    /// Fronts `toItem` with a directional slide, restarts the auto-advance dwell,
    /// and re-asserts focus on `keepButton` (clamped to the destination slide's
    /// button count). `forward` drives the wipe direction: the new backdrop slides
    /// in from the trailing edge (forward) or leading edge (backward), while the
    /// outgoing backdrop recedes a shorter distance and fades behind it.
    private func advance(to toItem: Int, keepButton: Int, forward: Bool) {
        guard items.indices.contains(toItem), toItem != index else { return }
        let old = current
        beginTransition()
        let token = slideToken
        let width = Self.screenWidth

        // Phase 1 (synchronous, no animation): front the new slide and place the
        // two backdrop layers at their start offsets — the incoming one a full
        // screen off, the outgoing one centered.
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            outgoing = old
            index = toItem
            incomingOffset = forward ? width : -width
            outgoingOffset = 0
            outgoingOpacity = 1
        }

        advanceToken &+= 1
        // Only re-assert focus when the hero already holds it (a manual page):
        // the auto-advance timer runs while focus is on the row below, and
        // assigning `@FocusState` there would yank focus up to the hero.
        if focusedButton != nil {
            let destinationButtons = buttons(for: items[toItem]).count
            focusedButton = min(keepButton, max(0, destinationButtons - 1))
        }

        // Phase 2 (next runloop tick): animate the layers to rest. This MUST be a
        // separate turn — setting the off-screen offset and animating it back in
        // the same cycle makes SwiftUI coalesce them to a net-zero change, so the
        // new artwork would just pop in with no slide (the intermittent bug).
        DispatchQueue.main.async {
            guard slideToken == token else { return }
            withAnimation(.easeInOut(duration: 0.42)) {
                incomingOffset = 0
                outgoingOffset = forward ? -width * 0.35 : width * 0.35
                outgoingOpacity = 0
            }
        }

        // Drop the outgoing layer once the wipe has landed (unless a newer page
        // has already started), and warm the new neighbours' artwork.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            guard slideToken == token else { return }
            outgoing = nil
        }
        Task { await resolveArtwork(around: toItem) }
    }

    /// Pages one slide forward (wrapping), keeping focus on the destination's
    /// chevron so repeated chevron presses / right-edge presses walk through the
    /// carousel. Used by the chevron button, a right-edge press, and auto-advance.
    private func advanceForward() {
        guard items.count > 1 else { return }
        let next = (index + 1) % items.count
        let destinationButtons = buttons(for: items[next]).count
        advance(to: next, keepButton: destinationButtons - 1, forward: true)
    }

    /// Pages one slide backward (wrapping), keeping focus on the left-most button
    /// (Play) — the only button from which the backward sentinel is reachable.
    private func advanceBackward() {
        guard items.count > 1 else { return }
        let prev = (index - 1 + items.count) % items.count
        advance(to: prev, keepButton: 0, forward: false)
    }

    /// Starts a slide change: sets the wipe direction and hides the current
    /// slide's metadata *immediately* (no animation), then schedules its fade-in
    /// once the backdrop wipe has landed. Guarded by ``slideToken`` so a rapid
    /// second page cancels the first page's pending fade-in.
    private func beginTransition() {
        slideToken &+= 1
        let token = slideToken
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { metadataVisible = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
            guard slideToken == token else { return }
            withAnimation(.easeInOut(duration: 0.35)) { metadataVisible = true }
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

    /// The ordered primary backdrop URLs for a slide. Prefers the **resolved**
    /// series-level hero art (for an episode/season slide, the show's high-res
    /// backdrop — the same class of art the detail page shows, not the low-res
    /// episode still) once it's been fetched; until then it uses the item's own
    /// backdrop so the slide is never blank.
    private func primaryBackdropURLs(for item: MediaItem) -> [URL] {
        if let resolved = resolvedBackdrop[item.id] { return [resolved] }
        return [item.heroBackdropURL, item.backdropURL].compactMap { $0 }
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
    /// image cache. For an **episode/season** the router query is series-scoped
    /// (it uses the parent show's title), so this yields the show's hero art —
    /// correct and high-res — rather than the episode's own still. Whole titles
    /// keep their server-provided hero backdrop (already high-res) and only reach
    /// for the router when the server gave none.
    @MainActor
    private func resolveArtwork(for item: MediaItem) async {
        guard resolvedBackdrop[item.id] == nil else { return }
        var best: URL?
        switch item.kind {
        case .episode, .season:
            best = await ArtworkRouter.shared.artworkURL(.hero, for: item)
            if best == nil { best = item.heroBackdropURL ?? item.backdropURL }
        case .folder, .collection, .unknown:
            best = item.heroBackdropURL ?? item.backdropURL
        default:
            best = item.heroBackdropURL ?? item.backdropURL
            if best == nil { best = await ArtworkRouter.shared.artworkURL(.hero, for: item) }
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
