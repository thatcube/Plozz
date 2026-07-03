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
    /// Fraction of the screen height the hero occupies. Full-screen, matching the
    /// Apple TV app: the backdrop fills the display top-to-bottom and the Continue
    /// Watching row is pulled up to peek just below the paging dots (see
    /// `HomeView.heroRowOverlap`), rather than the hero being shortened.
    var heroHeightFraction: CGFloat = 1.0
    let onSelect: (MediaItem) -> Void
    let onPlay: (MediaItem) -> Void

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

    @Environment(\.colorScheme) private var colorScheme

    private var current: MediaItem? {
        guard items.indices.contains(index) else { return items.first }
        return items[index]
    }

    /// Legibility scrim tone — dark in dark mode, light in light mode (matching
    /// the detail hero).
    private var scrimTone: Color { colorScheme == .dark ? .black : .white }

    /// The action buttons the current slide offers, in visual (left-to-right)
    /// order. `.play` and `.moreInfo` are always present; `.watchlist` only when
    /// the shared action handler exposes a watchlist toggle for `item`.
    private func buttons(for item: MediaItem) -> [HeroButton] {
        var result: [HeroButton] = [.play, .moreInfo]
        if watchlistAction(for: item) != nil { result.append(.watchlist) }
        return result
    }

    /// The watchlist toggle action for `item`, if its provider supports it.
    private func watchlistAction(for item: MediaItem) -> MediaItemAction? {
        actionHandler?.actions(for: item, context: actionContext)
            .first { $0 == .addToWatchlist || $0 == .removeFromWatchlist }
    }

    private static var screenHeight: CGFloat {
        #if canImport(UIKit)
        return UIScreen.main.bounds.height
        #else
        return 1080
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
            if let item = current {
                heroBackdrop(for: item, height: height)
                    .id(item.id)
                    .transition(.opacity)
            }
        }
        .opacity(heroVisible ? 1 : 0)
        .onAppear {
            guard !heroVisible else { return }
            withAnimation(.easeInOut(duration: 0.35)) { heroVisible = true }
            if focusedButton == nil { focusedButton = 0 }
        }
        // Cross-fade the whole slide (backdrop + text) as the carousel advances.
        .animation(.easeInOut(duration: 0.35), value: index)
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
            advance(to: (index + 1) % items.count, keepButton: focusedButton ?? 0)
        }
    }

    /// The dwell key: any change (slide index, focus state, or a manual page
    /// bump) restarts the auto-advance timer from the current slide.
    private var autoAdvanceKey: String {
        "\(index)-\(hasFocus)-\(advanceToken)"
    }

    // MARK: - Content column

    @ViewBuilder
    private func content(for item: MediaItem) -> some View {
        let hideText = spoilerSettings.shouldHideText(for: item)
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

            actionRow(for: item)
            pagingDots
        }
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
        HStack(spacing: 24) {
            ForEach(Array(itemButtons.enumerated()), id: \.element) { offset, button in
                actionButton(button, at: offset, for: item)
            }
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
        // Drive the exact paging model. `.onMoveCommand` fires for the focused
        // button; the reducer decides whether this is an interior move (let the
        // focus engine handle it natively), an edge advance/step, a sidebar
        // escape, or a blocked no-op.
        .onMoveCommand { direction in
            handleMove(direction)
        }
        .onChange(of: focusedButton) { _, new in
            hasFocus = new != nil
        }
    }

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
        case .moreInfo:
            Button {
                onSelect(item)
            } label: {
                Label("More Info", systemImage: "info.circle")
            }
            .modifier(HeroActionButtonStyle(prominent: false))
            .focused($focusedButton, equals: offset)
        case .watchlist:
            Button {
                if let action = watchlistAction(for: item) {
                    actionHandler?.perform(action, on: item, context: actionContext)
                }
            } label: {
                Image(systemName: item.isFavorite ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 30))
                    .foregroundStyle(item.isFavorite ? Color.accentColor : Color.primary)
                    .symbolEffect(.bounce, value: item.isFavorite)
                    .frame(width: 38, height: 38)
            }
            .modifier(HeroActionButtonStyle(prominent: false))
            .focused($focusedButton, equals: offset)
            .accessibilityLabel(item.isFavorite ? "Remove from Watchlist" : "Add to Watchlist")
        }
    }

    /// Applies the ``HeroCarouselFocus`` reducer to a remote move. Interior moves
    /// are left to the native focus engine (the reducer returns `.moveButton`,
    /// which the engine already performed); only edge paging and wrap are handled
    /// here.
    private func handleMove(_ direction: MoveCommandDirection) {
        guard let heroDirection = direction.heroDirection else { return }
        let buttonCount = current.map { buttons(for: $0).count } ?? 0
        let outcome = HeroCarouselFocus.resolve(
            direction: heroDirection,
            itemIndex: index,
            itemCount: items.count,
            focusedButton: focusedButton ?? 0,
            buttonCount: buttonCount,
            navigationStyle: navigationStyle
        )
        switch outcome {
        case .moveButton, .escape, .blocked:
            // Interior moves and sidebar-escape are handled by the native focus
            // engine; blocked is a no-op.
            break
        case let .advance(toItem, keepButton):
            advance(to: toItem, keepButton: keepButton)
        }
    }

    /// Fronts `toItem`, restarts the auto-advance dwell, and re-asserts focus on
    /// the same button index (clamped to the destination slide's button count so
    /// a slide with fewer buttons never leaves focus in limbo).
    private func advance(to toItem: Int, keepButton: Int) {
        guard items.indices.contains(toItem) else { return }
        withAnimation(.easeInOut(duration: 0.35)) { index = toItem }
        advanceToken &+= 1
        let destinationButtons = buttons(for: items[toItem]).count
        focusedButton = min(keepButton, max(0, destinationButtons - 1))
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
            urls: [item.heroBackdropURL, item.backdropURL].compactMap { $0 },
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
        case play, moreInfo, watchlist
    }
}

private extension MoveCommandDirection {
    /// Maps only horizontal moves to the carousel's paging directions; vertical
    /// moves return `nil` so up/down navigate natively (into the CW row / tabs).
    var heroDirection: HeroFocusDirection? {
        switch self {
        case .left: return .left
        case .right: return .right
        default: return nil
        }
    }
}
#endif
