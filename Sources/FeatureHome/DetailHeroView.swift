#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI
import MetadataKit
#if canImport(UIKit)
import UIKit
#endif

/// The top "hero" section of a detail page: a full-bleed backdrop with the
/// item's title, subtitle, ratings, overview, and an optional Play button.
///
/// It is intentionally stateless and driven entirely by `item`, so a parent can
/// swap which item it shows (series → focused season → focused episode) and the
/// whole hero animates to reflect the newly focused context.
struct DetailHeroView: View {
    let item: MediaItem
    /// The item whose artwork fills the backdrop. Defaults to `item`. A series
    /// page pins this to the series itself so the background stays a single,
    /// stable, high-quality image even as `item` (the focused season/episode)
    /// drives the logo, title, overview and Play button. Swapping the backdrop
    /// per focused episode reads as distracting flicker, so we don't.
    var backdropItem: MediaItem?
    /// Fraction of the screen height the hero backdrop occupies. Defaults to a
    /// full-screen cinematic hero (`1.0`); a TV show shrinks this (e.g. `0.8`) so
    /// the season tabs and episode row peek above the fold, signalling there's
    /// more to scroll to.
    var heroHeightFraction: CGFloat = 1.0
    let spoilerSettings: SpoilerSettings
    /// Title for the Play/Resume button, or `nil` to omit the button entirely
    /// (e.g. a season with no resolved episodes yet).
    let playTitle: String?
    let onPlay: (() -> Void)?
    /// When provided (`0..<1`), a thin watched-progress bar is shown inside the
    /// Play button, between the play icon and the remaining-time line.
    var playProgress: Double? = nil
    /// When provided, a "… left" remaining-time line is shown inside the Play
    /// button, after the progress bar.
    var playRemainingText: String? = nil
    /// When provided, a secondary "Trailer" button is shown next to Play.
    var onPlayTrailer: (() -> Void)? = nil
    /// The selectable versions for this title. When more than one exists and
    /// `onSelectVersion` is set, a "Version" picker button is shown next to Play
    /// so the user can choose which source `Play` targets.
    var versions: [MediaVersion] = []
    /// The currently-effective selected version id (drives the picker's label and
    /// the menu checkmark). `nil` falls back to the first/recommended version.
    var selectedVersionID: String? = nil
    /// This device's capabilities, used to predict Direct Play vs Transcode for
    /// each version in the picker (the creative compatibility badge).
    var capabilities: MediaCapabilities = .detected()
    /// Invoked with the chosen `MediaVersion.id` when the user picks a version.
    var onSelectVersion: ((String) -> Void)? = nil
    /// Technical badges to show when the focused item carries none of its own —
    /// a series or season hero has no media file, so the parent derives a
    /// representative set from the loaded episodes (best resolution/HDR/audio)
    /// and passes it here so a show still advertises 4K/Dolby Vision/Atmos.
    var fallbackTechnicalBadges: [MediaBadge] = []
    /// When provided, the hero's Play button binds to this focus state (as
    /// `true`), letting a parent give Play initial focus — used when a page is
    /// opened targeting a specific episode so focus lands on Play at the top
    /// rather than down in the episode row.
    var playButtonFocus: FocusState<Bool>.Binding? = nil

    /// Local focus state of the Play button, so the inline resume progress bar
    /// can flip its colours to stay visible against the button's focused (white)
    /// vs unfocused (dark) background.
    @FocusState private var playButtonHasFocus: Bool

    /// The app-installed action handler (the SAME one the press-and-hold context
    /// menu reads). Drives the visible Watchlist / Watched / Refresh hero buttons
    /// so they are byte-for-byte consistent with the long-press menu — optimistic
    /// update, cross-provider fan-out and mutation broadcast all go through it.
    /// `nil` in previews/tests, which simply hides the buttons.
    @Environment(\.mediaItemActionHandler) private var actionHandler
    /// Surrounding-list context, so a hero acting on a focused episode behaves
    /// exactly like that episode's context-menu would.
    @Environment(\.mediaItemActionContext) private var actionContext
    /// Drives the Refresh button's animated state machine: the refresh itself is
    /// a fire-and-forget server task, so this gives the user visible feedback —
    /// idle ➝ a spinning "refreshing" indicator ➝ a green success check ➝ back to
    /// idle, with each icon animating in and out.
    @State private var refreshPhase: RefreshPhase = .idle

    /// The visible lifecycle of the Refresh Metadata button.
    private enum RefreshPhase {
        case idle, refreshing, success
    }

    /// The item supplying the backdrop artwork (the pinned series, when set).
    private var backdrop: MediaItem { backdropItem ?? item }

    // MARK: - Visible item actions (discoverability)

    /// The capability-gated actions the installed handler offers for the focused
    /// `item`. Identical to what the context menu shows, so the visible buttons
    /// and the long-press menu can never drift apart.
    private var heroActions: [MediaItemAction] {
        actionHandler?.actions(for: item, context: actionContext) ?? []
    }

    /// The watchlist toggle for `item`, if its resolving provider conforms to
    /// `WatchlistProviding` (offered only for whole titles — movies/series).
    private var heroWatchlistAction: MediaItemAction? {
        heroActions.first { $0 == .addToWatchlist || $0 == .removeFromWatchlist }
    }

    /// The watched-state toggle for `item`, if its provider can mutate it. On a
    /// series page this lights up for the focused *episode* (the hero mirrors it),
    /// giving episodes a visible watched toggle without touching the rail.
    private var heroWatchedAction: MediaItemAction? {
        heroActions.first { $0 == .markWatched || $0 == .markUnwatched }
    }

    /// Whether to show the Refresh Metadata button (provider conforms to
    /// `MetadataRefreshing`).
    private var heroOffersRefresh: Bool { heroActions.contains(.refreshMetadata) }

    /// Whether any visible item-action button should render — used to decide
    /// whether the action row appears even when there's no Play/Trailer/Version.
    private var hasHeroActionButtons: Bool {
        heroWatchlistAction != nil || heroWatchedAction != nil || heroOffersRefresh
    }

    /// Routes a hero button through the shared action handler with this hero's
    /// item + context — the exact same path the context menu uses.
    private func performHeroAction(_ action: MediaItemAction) {
        actionHandler?.perform(action, on: item, context: actionContext)
    }

    /// The capability badges shown above the ratings: the content-rating
    /// certificate (e.g. `TV-14`) leading, then resolution/HDR/audio badges.
    /// When the focused item is an episode without its own certificate, the
    /// rating falls back to the backdrop item (the series), so a show's TV
    /// rating still shows while scrubbing episodes — matching Apple TV.
    private var featureBadges: [MediaBadge] {
        let rating = item.ratingBadge ?? backdrop.ratingBadge
        // Prefer the focused item's own tech badges; fall back to the derived
        // series-level set for a series/season hero (or an episode whose stream
        // info hasn't loaded), so tech badges are present on every kind.
        let ownTech = item.technicalBadges
        let tech = ownTech.isEmpty ? fallbackTechnicalBadges : ownTech
        return (rating.map { [$0] } ?? []) + tech
    }

    /// External ratings to show. Falls back to the backdrop item (the series)
    /// when the focused item (an episode) carries none of its own, so a show's
    /// rating stays visible while scrubbing episodes.
    private var heroRatings: [ExternalRating] {
        item.ratings.isEmpty ? backdrop.ratings : item.ratings
    }

    /// True when `subtitle` is just the production year — the richer metadata
    /// line below already opens with the year, so we drop the duplicate.
    private func isYearOnlySubtitle(_ subtitle: String) -> Bool {
        guard let year = item.productionYear else { return false }
        return subtitle == String(year)
    }

    var body: some View {
        let hideText = spoilerSettings.shouldHideText(for: item)
        let hideThumbnail = spoilerSettings.shouldHideThumbnail(for: item)
        let heroHeight = Self.screenHeight * heroHeightFraction
        // The leading-aligned content column. It is the ONLY thing that sizes the
        // hero, so the hero always reports the safe viewport width — never the
        // full panel — keeping its title/logo/Play on-screen and focusable.
        VStack(alignment: .leading, spacing: 12) {
            if hideText {
                titleText(hideText: hideText)
            } else {
                HeroLogoArtwork(
                    primaryURL: item.logoURL,
                    asyncFallbackURL: tmdbLogoFallback
                ) {
                    titleText(hideText: hideText)
                }
            }
            if let subtitle = item.subtitle, !isYearOnlySubtitle(subtitle) {
                Text(subtitle)
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            let metadata = item.metadataComponents()
            if !metadata.isEmpty {
                Text(metadata.joined(separator: "  ·  "))
                    .font(.system(size: 23, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if !hideText, let tagline = item.tagline {
                Text(tagline)
                    .font(.system(size: 24, weight: .medium))
                    .italic()
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: 960, alignment: .topLeading)
            }
            if !featureBadges.isEmpty {
                MediaBadgeRow(badges: featureBadges)
            }
            if !heroRatings.isEmpty && !spoilerSettings.shouldHideRatings(for: item) {
                RatingsBadgeRow(ratings: heroRatings)
            }
            if hideText {
                Label("Overview hidden to avoid spoilers", systemImage: "eye.slash.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 960, alignment: .topLeading)
            } else if let overview = item.overview {
                Text(overview)
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    // Reserve three lines of height even when the text is
                    // shorter, so swapping the focused item never makes the
                    // controls below jump up and down.
                    .lineLimit(3, reservesSpace: true)
                    .frame(maxWidth: 960, alignment: .topLeading)
            }
            if (playTitle != nil && onPlay != nil) || onPlayTrailer != nil || (versions.count > 1 && onSelectVersion != nil) || hasHeroActionButtons {
                HStack(spacing: 24) {
                    if let playTitle, let onPlay {
                        playButton(title: playTitle, action: onPlay)
                    }
                    if versions.count > 1, let onSelectVersion {
                        versionButton(onSelect: onSelectVersion)
                    }
                    if let onPlayTrailer {
                        Button(action: onPlayTrailer) {
                            Label("Trailer", systemImage: "film.fill")
                        }
                        .modifier(HeroButtonStyle(prominent: false))
                    }
                    if let heroWatchlistAction {
                        watchlistButton(action: heroWatchlistAction)
                    }
                    if let heroWatchedAction {
                        watchedButton(action: heroWatchedAction)
                    }
                    if heroOffersRefresh {
                        refreshButton()
                    }
                }
                .padding(.top, 8)
                // Make the action row its own focus section so pressing "up" from
                // a season parked far to the right reliably lands here. Note we no
                // longer stretch this to `.infinity`: a full-width focusable HStack
                // inside the hero, combined with the over-wide full-bleed backdrop,
                // was part of what let the focus engine pan the page off the left
                // edge. Leading-sized + `.focusSection()` keeps the "up" target
                // without contributing any over-wide focusable geometry.
                .focusSection()
            }
        }
        .padding(.vertical, PlozzTheme.Metrics.screenPadding)
        .padding(.trailing, PlozzTheme.Metrics.screenPadding)
        .padding(.leading, PlozzTheme.Metrics.heroLeadingPadding)
        // Occupy the backdrop's height and pin the content to the bottom-leading
        // corner — exactly what the old `ZStack(alignment: .bottomLeading)` did,
        // but measured at the *safe* viewport width (`.infinity` reports the
        // proposed width), never the full 1920pt panel.
        .frame(maxWidth: .infinity, minHeight: heroHeight, alignment: .bottomLeading)
        // The full-bleed backdrop lives in a `.background`, which by definition is
        // sized to the host and does NOT contribute to the host's measured size.
        // That is the fix: previously the backdrop was a ZStack *sibling* whose
        // `.ignoresSafeArea(.horizontal)` inflated the ZStack — and therefore the
        // whole scroll column — to the full panel width (~1920). A vertical
        // ScrollView then centred that over-wide content, throwing the
        // leading-aligned title/Play off the left edge while the centred image
        // still looked correct. As a background, the image bleeds edge-to-edge
        // purely visually and the content column stays at the safe width.
        .background(alignment: .bottom) {
            heroBackdrop(hideThumbnail: hideThumbnail)
        }
        // Cross-fade the hero text as the focused context changes, while the
        // backdrop swaps underneath it.
        .animation(.easeInOut(duration: 0.2), value: item.id)
    }

    /// The full-bleed backdrop image with its legibility scrim and bottom
    /// dissolve mask. Rendered as a `.background` of the hero content so it can
    /// ignore the horizontal/top overscan safe area and span the screen edge to
    /// edge *without* inflating the hero's (and the scroll column's) layout width.
    @ViewBuilder
    private func heroBackdrop(hideThumbnail: Bool) -> some View {
        FallbackAsyncImage(
            urls: [backdrop.heroBackdropURL, backdrop.backdropURL].compactMap { $0 },
            maxAspectRatio: 3.0,
            asyncFallbackURL: tmdbBackdropFallback
        ) {
            heroPlaceholder
        }
        .frame(height: Self.screenHeight * heroHeightFraction)
        .frame(maxWidth: .infinity)
        .clipped()
        .blur(radius: hideThumbnail && spoilerSettings.mode == .blur ? 40 : 0)
        .overlay(
            // Legibility scrim: darken the lower image so the title/overview
            // read clearly. It lives *under* the mask below, so it dissolves
            // away with the image and never tints the revealed background.
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: .clear, location: 0.5),
                    .init(color: .black.opacity(0.7), location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        // Dissolve the backdrop's own alpha to transparent over the lower
        // portion (top third stays a clean image) so the real `AppBackground`
        // shows straight through. Because that is the *same* fixed surface the
        // content below sits on, the transition is perfectly seamless — there
        // is no second colour to mismatch, so no hard line ever appears.
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .white, location: 0.0),
                    .init(color: .white, location: 0.33),
                    .init(color: .clear, location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        // Break out of the tvOS overscan safe area so the backdrop spans the
        // full screen edge to edge — across the top as well, otherwise the
        // top overscan inset shows through as a black bar above the artwork.
        .ignoresSafeArea(edges: [.top, .horizontal])
    }

    /// The hero Play button. Extracted so the optional initial-focus binding can
    /// be applied to it conditionally (a `nil` binding leaves default focus
    /// behaviour untouched). When the resume target is partially watched the
    /// label becomes `▶  [progress bar]  … left`, keeping the button's normal
    /// height; otherwise it's the plain `▶  Play/Resume`.
    @ViewBuilder
    private func playButton(title: String, action: @escaping () -> Void) -> some View {
        let button = Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: "play.fill")
                if let playRemainingText, let playProgress, playProgress > 0, playProgress < 1 {
                    resumeProgressCapsule(progress: playProgress)
                    Text(playRemainingText)
                } else {
                    Text(title)
                }
            }
            .frame(minWidth: 260)
        }
        .modifier(HeroButtonStyle(prominent: true))
        .focused($playButtonHasFocus)

        if let playButtonFocus {
            button.focused(playButtonFocus, equals: true)
        } else {
            button
        }
    }

    /// The version-picker button shown next to Play when a title has more than
    /// one source. Its label reflects the currently-selected version's quality
    /// ("4K · Dolby Vision"); the menu lists every version with a visual quality
    /// diff and a predicted Direct Play / Transcode badge for *this* device, with
    /// a checkmark on the active one.
    @ViewBuilder
    private func versionButton(onSelect: @escaping (String) -> Void) -> some View {
        let current = versions.first { $0.id == selectedVersionID } ?? versions.first
        Menu {
            ForEach(versions) { version in
                Button {
                    onSelect(version.id)
                } label: {
                    let badge = version.compatibility(with: capabilities).badge
                    let suffix = badge.isEmpty ? "" : "  •  \(badge)"
                    if version.id == current?.id {
                        Label(version.displayLabel + suffix, systemImage: "checkmark")
                    } else {
                        Text(version.displayLabel + suffix)
                    }
                }
            }
        } label: {
            Label(current?.resolutionLabel ?? "Version", systemImage: "rectangle.stack.fill")
                .frame(minWidth: 160)
        }
        .modifier(HeroButtonStyle(prominent: false))
    }

    /// Visible Watchlist toggle, shown when the resolving provider conforms to
    /// `WatchlistProviding`. A filled bookmark + "Watchlisted" reflects current
    /// membership; an outline bookmark + "Watchlist" prompts adding. Tapping
    /// routes through the shared handler (optimistic update + cross-provider
    /// fan-out), so the icon flips the instant the mutation broadcasts back.
    @ViewBuilder
    private func watchlistButton(action: MediaItemAction) -> some View {
        Button { performHeroAction(action) } label: {
            Image(systemName: item.isFavorite ? "bookmark.fill" : "bookmark")
                .foregroundStyle(item.isFavorite ? Color.accentColor : Color.primary)
                .contentTransition(.opacity)
                .symbolEffect(.bounce, value: item.isFavorite)
        }
        .modifier(HeroButtonStyle(prominent: false))
        .animation(.easeInOut(duration: 0.2), value: item.isFavorite)
        .accessibilityLabel(action.title)
        .accessibilityValue(item.isFavorite ? "On your watchlist" : "Not on your watchlist")
    }

    /// Visible watched-state toggle, shown when the provider can mutate it. On a
    /// series page the hero mirrors the focused episode, so this doubles as the
    /// episode's visible watched toggle. Unwatched shows a neutral `eye`; marking
    /// watched swaps it for a brand-blue filled circle with a white check (the
    /// same watched colour as the episode cards), the eye scaling/fading out as
    /// the check scales in on a single timeline so it stays in sync with the
    /// button's own focus animation.
    @ViewBuilder
    private func watchedButton(action: MediaItemAction) -> some View {
        Button { performHeroAction(action) } label: {
            Group {
                if item.isPlayed {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, ThemePalette.brandBlue)
                } else {
                    Image(systemName: "eye")
                        .foregroundStyle(Color.primary)
                }
            }
            .id(item.isPlayed)
            .transition(.scale.combined(with: .opacity))
        }
        .modifier(HeroButtonStyle(prominent: false))
        .animation(.easeInOut(duration: 0.22), value: item.isPlayed)
        .accessibilityLabel(action.title)
        .accessibilityValue(item.isPlayed ? "Watched" : "Not watched")
    }

    /// Visible Refresh Metadata button, shown when the provider conforms to
    /// `MetadataRefreshing`. The server task is fire-and-forget, so the icon walks
    /// through a small animated state machine for feedback: a real spinning
    /// progress indicator while "refreshing", then a brand-blue success check,
    /// then back to the refresh glyph — each state scaling/fading in and out.
    @ViewBuilder
    private func refreshButton() -> some View {
        Button {
            guard refreshPhase == .idle else { return }
            performHeroAction(.refreshMetadata)
            setRefreshPhase(.refreshing)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                setRefreshPhase(.success)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
                    setRefreshPhase(.idle)
                }
            }
        } label: {
            refreshIcon
        }
        .modifier(HeroButtonStyle(prominent: false))
        .accessibilityLabel(MediaItemAction.refreshMetadata.title)
    }

    /// Animates the refresh state transition.
    private func setRefreshPhase(_ phase: RefreshPhase) {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.72)) {
            refreshPhase = phase
        }
    }

    /// The single glyph shown for the current `refreshPhase`. Keyed by phase so a
    /// change removes the old glyph (transition out) and inserts the new one
    /// (transition in); the refreshing phase shows a real circular spinner.
    @ViewBuilder
    private var refreshIcon: some View {
        Group {
            switch refreshPhase {
            case .idle:
                Image(systemName: "arrow.clockwise")
            case .refreshing:
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(ThemePalette.brandBlue)
                    .scaleEffect(0.9)
            case .success:
                Image(systemName: "checkmark")
                    .foregroundStyle(ThemePalette.brandBlue)
            }
        }
        .id(refreshPhase)
        .transition(.scale(scale: 0.4).combined(with: .opacity))
    }
    /// play icon and the "… left" line. Its colours flip with the button's focus
    /// state — light fill on the dark unfocused button, dark fill on the white
    /// focused button — so it stays clearly visible either way.
    private func resumeProgressCapsule(progress: Double) -> some View {
        let onLight = playButtonHasFocus
        let track = onLight ? Color.black.opacity(0.22) : Color.white.opacity(0.32)
        let fill = onLight ? Color.black.opacity(0.85) : Color.white
        let width: CGFloat = 150
        return Capsule()
            .fill(track)
            .frame(width: width, height: 6)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(fill)
                    .frame(width: max(8, width * progress), height: 6)
            }
            .animation(.easeInOut(duration: 0.2), value: onLight)
    }

    /// The plain text title, used both under spoilers and as the fallback when no
    /// logo art can be resolved. Width is capped (and the text wraps/scales) so a
    /// very long title can never render as a single line wider than the screen —
    /// which would blow the hero's content past the viewport and shove the whole
    /// page (title + focusable buttons) off the left edge.
    private func titleText(hideText: Bool) -> some View {
        Text(hideText ? spoilerSettings.maskedTitle(for: item) : item.title)
            .font(.system(size: 64, weight: .bold))
            .lineLimit(2)
            .minimumScaleFactor(0.5)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: 1200, alignment: .leading)
    }

    /// Full screen height, the basis for the backdrop's height (scaled by
    /// `heroHeightFraction`). Falls back to a 1080p constant where UIKit isn't
    /// available (non-Apple toolchains/tests).
    private static var screenHeight: CGFloat {
        #if canImport(UIKit)
        return UIScreen.main.bounds.height
        #else
        return 1080
        #endif
    }

    /// The hero's final, always-keyless background when no real landscape art is
    /// available from the server or any external provider. Rather than a flat grey
    /// panel, it blows up the item's own poster, scaled to fill and heavily blurred
    /// into a soft cinematic wash, so a movie/show with only a poster still gets a
    /// rich coloured hero instead of an empty one. Falls back to the neutral fill
    /// only when there is no poster at all.
    @ViewBuilder
    private var heroPlaceholder: some View {
        if let poster = backdrop.posterURL {
            AsyncImage(url: poster) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .blur(radius: 60)
                        .scaleEffect(1.2)
                        .overlay(Color.black.opacity(0.35))
                default:
                    Rectangle().fill(.tertiary)
                }
            }
        } else {
            Rectangle().fill(.tertiary)
        }
    }

    /// Last-resort backdrop art for the hero: look the show/movie up on TMDb and
    /// use a wide fanart image. Many anime (via Shoko/AniDB) ship no backdrop, so
    /// this fills the otherwise-empty hero. Uses the *backdrop* item (the series,
    /// when pinned) and its TMDb id when that id refers to the show itself; for an
    /// episode/season backdrop it queries by series title. Inert without a token.
    private var tmdbBackdropFallback: (@Sendable () async -> URL?)? {
        let source = backdrop
        switch source.kind {
        case .folder, .collection, .unknown:
            return nil
        default:
            break
        }
        return {
            await ArtworkRouter.shared.artworkURL(.hero, for: source)
        }
    }

    /// Last-resort title art for the hero: look the show/movie up on TMDb and use
    /// its logo. TV uses the *series* title (never an episode name); inert when no
    /// TMDb token is configured.
    private var tmdbLogoFallback: (@Sendable () async -> URL?)? {
        let source = item
        switch source.kind {
        case .folder, .collection, .unknown:
            return nil
        default:
            break
        }
        return {
            await ArtworkRouter.shared.artworkURL(.logo, for: source)
        }
    }
}

/// Applies the native Liquid Glass button style to the hero's action buttons on
/// OS versions that ship it (tvOS 26+), falling back to the classic bordered
/// styles below that. `prominent` picks the tinted primary glass (Play) versus
/// the lighter clear glass (secondary actions like Trailer).
private struct HeroButtonStyle: ViewModifier {
    let prominent: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(tvOS 26.0, *) {
            if prominent {
                content.buttonStyle(.glassProminent)
            } else {
                content.buttonStyle(.glass)
            }
        } else {
            if prominent {
                content.buttonStyle(.borderedProminent)
            } else {
                content.buttonStyle(.bordered)
            }
        }
    }
}

#endif
