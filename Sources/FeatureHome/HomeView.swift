#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// The Home screen: an optional cinematic **hero** carousel followed by
/// Continue Watching, Latest, and library shortcuts.
public struct HomeView: View {
    @State private var viewModel: HomeViewModel
    private var visibility: HomeLibraryVisibilityModel
    private let spoilerSettings: SpoilerSettings
    private let onSelectItem: (MediaItem) -> Void
    private let onPlayItem: (MediaItem) -> Void
    private let onSelectLibrary: (MediaLibrary) -> Void

    /// Per-profile hero configuration. `nil` (or an inactive config) leaves Home
    /// rendering its classic rows unchanged.
    private var heroSettings: HeroSettingsModel?
    private let heroCurator: HeroCurator
    private let heroFeaturedProvider: FeaturedContentProviding
    private let heroRandomProvider: RandomLibraryContentProviding
    /// The app-wide navigation style, so the carousel's left-edge behaviour
    /// (escape to sidebar vs. wrap) matches the surrounding chrome.
    private let navigationStyle: NavigationStyle

    /// The curated hero items, recomputed as Home content or settings change.
    @State private var heroItems: [MediaItem] = []

    /// Focus scope spanning the hero + rows; lets the hero's Play button be the
    /// preferred initial focus (see `.focusScope`/`prefersDefaultFocus`).
    @Namespace private var heroFocusScope

    @Environment(\.plozzMetrics) private var metrics

    public init(
        viewModel: HomeViewModel,
        visibility: HomeLibraryVisibilityModel,
        spoilerSettings: SpoilerSettings = .default,
        heroSettings: HeroSettingsModel? = nil,
        heroCurator: HeroCurator = HeroCurator(),
        heroFeaturedProvider: @escaping FeaturedContentProviding = HeroFeaturedProvider.none,
        heroRandomProvider: @escaping RandomLibraryContentProviding = HeroRandomProvider.none,
        navigationStyle: NavigationStyle = .default,
        onSelectItem: @escaping (MediaItem) -> Void,
        onPlayItem: @escaping (MediaItem) -> Void,
        onSelectLibrary: @escaping (MediaLibrary) -> Void
    ) {
        _viewModel = State(initialValue: viewModel)
        self.visibility = visibility
        self.spoilerSettings = spoilerSettings
        self.heroSettings = heroSettings
        self.heroCurator = heroCurator
        self.heroFeaturedProvider = heroFeaturedProvider
        self.heroRandomProvider = heroRandomProvider
        self.navigationStyle = navigationStyle
        self.onSelectItem = onSelectItem
        self.onPlayItem = onPlayItem
        self.onSelectLibrary = onSelectLibrary
    }

    public var body: some View {
        ContentStateView(
            state: viewModel.state,
            emptyMessage: "Your libraries are empty. Add media on your media server to see it here.",
            onRetry: { Task { await viewModel.load() } },
            loadingContent: { HomeSkeletonView(layout: viewModel.skeletonLayout) }
        ) { content in
            // The screen is a data-driven list of rows. Both this loaded view and
            // the skeleton render from the same ordered `HomeRow`/`HomeRowKind`
            // structure, which keeps them 1:1 and makes the order the single thing
            // a future row-customization feature edits. `HomeRow.rows` also applies
            // per-library Home-visibility to *every* row's items (not just the
            // Libraries tiles), so a hidden library's content is suppressed
            // app-wide; passing the reactive `isVisible` here keeps toggles taking
            // effect on the next render even before any re-fetch settles.
            let rows = HomeRow.rows(for: content) { visibility.isVisible($0) }
            // The descriptor the next launch's skeleton renders from: each row's
            // kind, order *and* how many cards it actually showed, so the skeleton
            // matches a full row and a sparse one alike.
            let layout = rows.map { HomeRowLayout(kind: $0.kind, count: $0.cardCount) }
            // Seed the hero synchronously from the already-loaded sources
            // (Continue Watching + Watchlist) so it renders in the *same frame* as
            // the rows — no pop-in. Once `recomputeHero` finishes, `heroItems`
            // (which also includes the async Featured/Random sources) takes over.
            let syncHeroItems = heroSettings.map {
                heroCurator.curateSync(
                    settings: $0.settings,
                    continueWatching: content.continueWatching,
                    watchlist: content.watchlist
                )
            } ?? []
            let displayHeroItems = heroItems.isEmpty ? syncHeroItems : heroItems
            let heroActive = (heroSettings?.settings.isActive ?? false) && !displayHeroItems.isEmpty
            // Account-scoped ids of every watchlisted title, so the hero can show
            // the *series'* watchlist state on an episode/season slide.
            let watchlistedKeys = Set(content.watchlist.map {
                HomeHeroView.watchlistKey(accountID: $0.sourceAccountID, itemID: $0.id)
            })
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if heroActive, let heroSettings {
                            HomeHeroView(
                                items: displayHeroItems,
                                settings: heroSettings.settings,
                                spoilerSettings: spoilerSettings,
                                navigationStyle: navigationStyle,
                                watchlistedKeys: watchlistedKeys,
                                focusScope: heroFocusScope,
                                onSelect: onSelectItem,
                                onPlay: onPlayItem,
                                // When focus returns to the hero from a row below,
                                // snap the scroll back to the top so the hero
                                // re-expands to full-screen and its transition
                                // replays — otherwise it stays partially scrolled.
                                onFocusGained: {
                                    withAnimation(.easeInOut(duration: 0.4)) {
                                        proxy.scrollTo(Self.heroTopID, anchor: .top)
                                    }
                                },
                                // Focus leaving the hero downward: recede. Scroll
                                // the anchor just above the buttons to ~12% down
                                // the screen, so the logo/title lift off the top,
                                // the overview/buttons/dots settle into the upper
                                // region, and the Continue Watching row centers
                                // below — the Apple TV "recede" move.
                                onMoveDown: {
                                    withAnimation(.easeInOut(duration: 0.45)) {
                                        proxy.scrollTo(
                                            HomeHeroView.recedeAnchorID,
                                            anchor: UnitPoint(x: 0.5, y: 0.12)
                                        )
                                    }
                                }
                            )
                            .id(Self.heroTopID)
                        }
                        VStack(alignment: .leading, spacing: metrics.rowSpacing) {
                            ForEach(rows) { row in
                                rowView(row)
                            }
                        }
                        // When the hero is present, pull the rows up so the first row
                        // (Continue Watching) overlaps the hero's lower edge — the
                        // Apple TV look. Otherwise keep the classic top padding.
                        .padding(.top, heroActive ? -Self.heroRowOverlap : PlozzTheme.Metrics.screenVerticalPadding)
                        .padding(.bottom, PlozzTheme.Metrics.screenVerticalPadding)
                    }
                    // Span the hero and rows in one focus scope so the hero's
                    // Play button can be the scope's preferred default — tvOS
                    // then lands initial focus on the hero instead of a Continue
                    // Watching card, with no visible focus steal-back.
                    .focusScope(heroFocusScope)
                }
                // Never clip a focused card's lift, shadow or border.
                .scrollClipDisabled()
                // When the hero is active, let it bleed into the top overscan
                // inset instead of the ScrollView reserving it as a blank bar
                // above the backdrop (the gap that made the hero sit too low).
                // An empty edge set is a no-op, so the classic rows layout keeps
                // its normal top inset under the tab bar.
                .ignoresSafeArea(.container, edges: heroActive ? .top : [])
            }
            // Remember the structure we actually rendered (post-visibility), keyed
            // on kinds *and* counts so a changed card count re-persists too.
            .task(id: layout) { viewModel.rememberLayout(layout) }
            // Recompute the curated hero set whenever Home content or the hero
            // config changes. Off the main actor via the curator's async sources.
            .task(id: HeroRecomputeKey(content: content, settings: heroSettings?.settings)) {
                await recomputeHero(content: content)
            }
        }
        .task(id: visibility.visibility.excludedKeys) {
            // First appearance loads; thereafter a change to the hidden-library set
            // re-aggregates so library-scoped providers (Jellyfin) re-fetch with the
            // new visible set. `loadIfNeeded` skips the reload on a bare reappearance
            // (tvOS restarts this `.task` every time Home returns from a pushed
            // detail), so back-navigation no longer flashes the skeleton or resets
            // focus. Providers that tag items inline (Plex) are also filtered live
            // above, so their toggles feel instant even before the reload settles.
            await viewModel.loadIfNeeded(excludedKeys: visibility.visibility.excludedKeys)
        }
        .onReceive(NotificationCenter.default.publisher(for: .mediaItemDidMutate)) { note in
            if let mutation = MediaItemMutation.from(note) {
                viewModel.applyWatchedState(mutation)
            } else {
                Task { await viewModel.load() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .identityIndexDidUpdate)) { _ in
            // The cross-server index warmed further; re-fold the fuller source set
            // into the loaded cards in place so a title that cold-loaded before its
            // local twin was known can now route playback to that local copy. No
            // refetch, and a no-op when no visible card gained a source. Coalesced:
            // the index publishes once per warmed account, so this arrives in a
            // burst on a multi-server boot — debounce to a single fold.
            viewModel.scheduleReenrich()
        }
    }

    /// How far the rows are pulled up so the first row (Continue Watching) peeks
    /// in just below the hero's paging dots — the Apple TV look. Paired with
    /// `HomeHeroView.contentBottomInset` (132): pulling up by slightly less than
    /// that inset lands the Continue Watching title ~40px below the dots, with the
    /// tops of its cards peeking over the hero's lower edge. Tuned on-device.
    private static let heroRowOverlap: CGFloat = 92

    /// Scroll anchor for the hero, so focus returning to it can snap the scroll
    /// back to the top and re-expand the hero to full-screen.
    private static let heroTopID = "home-hero-top"

    /// Recomputes the curated hero items for the current Home `content` and the
    /// active hero settings, via the injected curator + content seams. Clears the
    /// set when the hero is disabled so Home falls back to its classic layout.
    @MainActor
    private func recomputeHero(content: HomeViewModel.Content) async {
        guard let settings = heroSettings?.settings, settings.isActive else {
            heroItems = []
            return
        }
        // Resolve the Random source's library scope: an empty set means "all
        // currently-visible libraries", so expand it to concrete keys from the
        // loaded, visibility-filtered library set before handing off to the
        // provider (which then just fetches from the keys it's given).
        var effective = settings
        if settings.isEnabled(.randomFromLibrary) && settings.randomLibraryKeys.isEmpty {
            let visibleKeys = content.libraries
                .filter { visibility.isVisible($0.key) }
                .map(\.key)
            effective.randomLibraryKeys = Set(visibleKeys)
        }
        let items = await heroCurator.curate(
            settings: effective,
            continueWatching: content.continueWatching,
            watchlist: content.watchlist,
            featuredProvider: heroFeaturedProvider,
            randomProvider: heroRandomProvider
        )
        heroItems = items
    }

    /// Renders one resolved `HomeRow`. The per-kind wiring (card style, and
    /// whether selecting a card plays it or opens its detail) is exactly what the
    /// view used inline before the row model existed.
    @ViewBuilder
    private func rowView(_ row: HomeRow) -> some View {
        switch row.kind {
        case .continueWatching:
            MediaRowView(title: row.title, items: row.items, style: posterStyle(row.style), spoilerSettings: spoilerSettings, onSelect: onPlayItem)
        case .watchlist, .recentlyAdded:
            MediaRowView(title: row.title, items: row.items, style: posterStyle(row.style), spoilerSettings: spoilerSettings, onSelect: onSelectItem)
        case .libraries:
            librariesRow(row.libraries)
        }
    }

    /// Maps the SwiftUI-free `HomeRowStyle` back to the concrete card style.
    private func posterStyle(_ style: HomeRowStyle) -> PosterCardView.Style {
        switch style {
        case .poster: return .poster
        case .landscape: return .landscape
        }
    }

    private func librariesRow(_ libraries: [AggregatedLibrary]) -> some View {
        VStack(alignment: .leading, spacing: metrics.sectionTitleSpacing) {
            Text("Libraries")
                .font(.system(size: metrics.sectionHeaderFontSize, weight: .bold))
                .padding(.leading, PlozzTheme.Metrics.screenPadding)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: metrics.cardSpacing) {
                    ForEach(libraries) { aggregated in
                        LibraryCardView(
                            aggregated: aggregated,
                            subtitle: Self.librarySubtitle(for: aggregated, in: libraries),
                            action: { onSelectLibrary(aggregated.library) }
                        )
                    }
                }
                .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
                // Keep the rail clipping (no `scrollClipDisabled`) so the focus
                // engine doesn't yank the first/last tile flush to the screen edge,
                // and reserve room *inside* the clip for the focused tile's lift +
                // shadow. The negative outer padding cancels that room in layout, so
                // the row's height and spacing are unchanged — only the clip grows.
                .padding(.vertical, metrics.railShadowClearance)
            }
            .padding(.top, metrics.railTopClearanceOffset)
            .padding(.bottom, metrics.railBottomClearanceOffset)
        }
    }

    /// The tile's secondary line. Library TILES are never merged across servers,
    /// so two same-named libraries (e.g. "Movies" on two Plex servers, or two
    /// Jellyfin logins on one box) appear as distinct tiles — this surfaces enough
    /// of `serverName`/`accountName` to tell them apart. Shows the server name,
    /// and appends the account/user when another visible tile shares that server
    /// name (so the server alone is ambiguous); falls back to the account name
    /// when the server name is missing.
    static func librarySubtitle(for aggregated: AggregatedLibrary, in libraries: [AggregatedLibrary]) -> String {
        let server = aggregated.serverName.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = aggregated.accountName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !server.isEmpty else { return account }
        let serverIsAmbiguous = libraries.contains {
            $0.id != aggregated.id
                && $0.serverName == aggregated.serverName
                && $0.accountID != aggregated.accountID
        }
        if serverIsAmbiguous, !account.isEmpty, account != server {
            return "\(server) · \(account)"
        }
        return server
    }
}

/// The `.task(id:)` key that drives hero recomputation: any change to the loaded
/// Home content (Continue Watching / Watchlist feed the curator directly) or the
/// hero settings re-runs the curator. `Equatable` so SwiftUI restarts the task
/// only on a real change.
private struct HeroRecomputeKey: Equatable {
    let content: HomeViewModel.Content
    let settings: HeroSettings?
}

/// A Home "Libraries" tile. Mirrors `PosterCardView`'s landscape (medium-card)
/// chrome exactly — same glass surface, media inset, corner radii and focus
/// lift — so a library tile sits flush with the Continue Watching / Latest cards
/// and with the loading skeleton (which renders the same medium card). This is
/// what makes a library's corner radius match every other card on Home.
///
/// Libraries frequently ship **no** artwork (notably Plex sections, which return
/// a bare gray box), so the empty state is a themed accent→surface gradient with
/// a large, low-contrast per-kind glyph rather than a flat fill — an imageless
/// library still reads as an intentional, on-brand tile.
private struct LibraryCardView: View {
    let aggregated: AggregatedLibrary
    let subtitle: String
    let action: () -> Void

    @FocusState private var isFocused: Bool
    @Environment(\.themePalette) private var palette
    @Environment(\.plozzReduceTransparency) private var reduceTransparency
    @Environment(\.plozzMetrics) private var metrics
    /// Per-profile card presentation, so a Home "Libraries" tile switches between
    /// the framed glass card and the borderless "Posters" look with every other
    /// card on Home.
    @Environment(\.plozzCardStyle) private var cardStyle

    /// Title/subtitle colour, flipped to dark ink over a focused card's opaque
    /// "lift" surface — shared with every other card via `PlozzCardCaption` so the
    /// Libraries tile flips contrast on focus just like Continue Watching / Latest.
    private var titleColor: Color {
        PlozzCardCaption.titleColor(isFocused: isFocused, reduceTransparency: reduceTransparency)
    }
    private var subtitleColor: Color {
        PlozzCardCaption.subtitleColor(isFocused: isFocused, reduceTransparency: reduceTransparency)
    }

    var body: some View {
        switch cardStyle {
        case .framed:
            framedCard
        case .borderless:
            borderlessCard
        }
    }

    private var framedCard: some View {
        VStack(alignment: .leading, spacing: metrics.landscapeCaptionTopSpacing) {
            artwork
                .frame(width: metrics.landscapeWidth, height: metrics.landscapeHeight)
                .clipShape(RoundedRectangle(cornerRadius: PlozzTheme.Metrics.mediumMediaCornerRadius, style: .continuous))
                .plozzMediaEdge(cornerRadius: PlozzTheme.Metrics.mediumMediaCornerRadius)

            VStack(alignment: .leading, spacing: 4) {
                Text(aggregated.library.title)
                    .font(.system(size: metrics.cardTitleFontSize, weight: .semibold))
                    .foregroundStyle(titleColor)
                    .lineLimit(1)
                Text(subtitle.isEmpty ? " " : subtitle)
                    .font(.system(size: metrics.cardSubtitleFontSize))
                    .foregroundStyle(subtitleColor)
                    .lineLimit(1)
                    .opacity(subtitle.isEmpty ? 0 : 1)
            }
            .padding([.horizontal, .bottom], metrics.landscapeCaptionInset)
            .frame(width: metrics.landscapeWidth, alignment: .leading)
        }
        .padding(metrics.cardInset)
        .plozzGlassCard(cornerRadius: metrics.landscapeCardCornerRadius, isFocused: isFocused)
        .focusableCard(isFocused: $isFocused, cornerRadius: metrics.landscapeCardCornerRadius, action: action)
        .plozzCardRasterize(reduceTransparency: reduceTransparency)
        .shadow(color: .black.opacity(isFocused ? 0.36 : 0.15), radius: isFocused ? 20 : 8, y: isFocused ? 10 : 4)
        .scaleEffect(isFocused ? PlozzTheme.Metrics.mediumFocusedCardScale : 1)
        .zIndex(isFocused ? 2 : 0)
        .animation(.easeOut(duration: 0.18), value: isFocused)
    }

    /// The borderless ("Posters") Libraries tile: the library artwork with no glass
    /// surface, rounded at the outer radius, wearing the shared `plozzFocusHalo`
    /// focus ring and dropping its caption on focus — exactly like the borderless
    /// Continue Watching / Latest landscape cards, so a Libraries tile stays flush
    /// with them in either card style.
    private var borderlessCard: some View {
        let width = metrics.landscapeCardSlotWidth - metrics.borderlessCardSideMargin * 2
        return VStack(alignment: .leading, spacing: metrics.landscapeCaptionTopSpacing + metrics.focusCaptionPush) {
            Color.clear
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(width: width)
                .overlay { artwork }
                .clipShape(RoundedRectangle(cornerRadius: metrics.landscapeCardCornerRadius, style: .continuous))
                .plozzMediaEdge(cornerRadius: metrics.landscapeCardCornerRadius)
                .plozzFocusHalo(
                    cornerRadius: metrics.landscapeCardCornerRadius,
                    focusScale: PlozzTheme.Metrics.mediumFocusedCardScale,
                    isFocused: isFocused
                )

            BorderlessCardCaption(
                title: aggregated.library.title,
                subtitle: subtitle.isEmpty ? nil : subtitle,
                horizontalInset: metrics.landscapeCaptionInset
            )
            .frame(width: width)
            .offset(y: isFocused ? 0 : -metrics.focusCaptionPush)
        }
        .padding(.horizontal, metrics.borderlessCardSideMargin)
        .focusableCard(isFocused: $isFocused, cornerRadius: metrics.landscapeCardCornerRadius, action: action)
        .compositingGroup()
        .zIndex(isFocused ? 2 : 0)
        .animation(.easeOut(duration: 0.18), value: isFocused)
    }

    @ViewBuilder
    private var artwork: some View {
        if let url = aggregated.library.imageURL {
            AsyncImage(url: url) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                placeholder
            }
        } else {
            placeholder
        }
    }

    /// Themed empty-state for an imageless library. A subtle vertical gradient
    /// between the page's `backgroundBase` (top) and the opaque `cardOpaqueSurface`
    /// (bottom): close in value so the fill reads a touch brighter than the page
    /// yet never as a heavy gradient, and — because both stops come straight from
    /// the palette — it tracks light / dark and collapses to pure black in OLED
    /// (both stops are black there). Opaque, so the focus glass halo behind the
    /// card can't bleed through, and focus-independent so nothing jumps on focus.
    private var placeholder: some View {
        ZStack {
            LinearGradient(
                colors: [palette.backgroundBase, palette.cardOpaqueSurface],
                startPoint: .top,
                endPoint: .bottom
            )
            Image(systemName: librarySymbol)
                .font(.system(size: 64, weight: .semibold))
                .foregroundStyle(palette.secondaryText.opacity(0.4))
        }
    }

    /// A per-kind SF Symbol for the empty-state watermark. Plex/Jellyfin map
    /// movie and TV sections to `.movie`/`.series`; music and other sections come
    /// through as `.folder`, so the default covers music libraries too.
    private var librarySymbol: String {
        switch aggregated.library.kind {
        case .movie: return "film.stack.fill"
        case .series: return "tv.fill"
        case .collection: return "rectangle.stack.fill"
        default: return "square.stack.3d.up.fill"
        }
    }
}

#endif
