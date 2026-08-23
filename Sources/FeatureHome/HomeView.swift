#if canImport(SwiftUI)
import Observation
import SwiftUI
import CoreModels
import CoreNetworking
import CoreUI
import FeatureHomeCore
import HeroUI
import MetadataKit

/// Profile-scoped Hero state owned above the transient Home tab subtree. tvOS may
/// recreate a tab's view when switching away and back; retaining the last curated
/// items here prevents loaded content from regressing to a non-focusable skeleton.
@MainActor
@Observable
public final class HomeHeroRuntimeState {
    var items: [MediaItem] = []
    var completedKey: HeroRecomputeKey?
    /// Last launch's curated hero, hydrated once from the profile-scoped Home
    /// cache so the carousel paints in the first frame instead of a skeleton —
    /// before Seerr, the random draw, artwork validation and metadata enrichment
    /// have done anything. Holds no Continue Watching slides; see
    /// ``HeroCurationResult/durableItems``. Cleared once a real curation lands.
    var cachedItems: [MediaItem] = []
    var cachedKey: HeroConfigurationKey?
    var hasHydratedCache = false
    var externalRefreshRevision = 0
    /// The Random source's retained draw, so a background recomputation reuses the
    /// titles already on screen instead of re-shuffling every library on every
    /// connected server. See ``HeroRandomRollStore``.
    @ObservationIgnored let randomRolls = HeroRandomRollStore()
    /// The slides on screen: the fronted one, plus whatever a committed swipe is
    /// landing on. Written by `HomeHeroView` as it pages, and read only when
    /// folding a fresh curation in, so a slide the viewer is looking at is never
    /// the one evicted, retired, or swapped for a different record.
    /// Deliberately unobserved: it changes on every page and nothing renders from
    /// it, so observing it would invalidate Home for no reason.
    @ObservationIgnored var pinnedItemIDs: Set<String> = []
    /// How many consecutive curations have failed to offer each retained title, so
    /// a deleted or un-watchlisted one eventually leaves rather than haunting the
    /// carousel. See ``HeroLiveMerge``. Unobserved: only the fold reads it.
    @ObservationIgnored var retainedMisses: [String: Int] = [:]
    /// Live, in-session watched/unwatched intents replayed onto the hero until the
    /// durable snapshot catches up. Kept bounded via ``registerWatchMutation(_:)``.
    var watchMutations: [MediaItemMutation] = []
    var durableWatchMutations: [MediaItemMutation] = []
    var hasHydratedDurableMutations = false

    /// Safety cap on retained session overlays, beyond the per-target coalescing in
    /// ``registerWatchMutation(_:)`` — a pathological session still can't grow the
    /// list without bound. Realistic sessions stay far below this.
    static let maxSessionWatchMutations = 128

    public init() {}

    public func resetForSourceScopeChange() {
        items = []
        completedKey = nil
        cachedItems = []
        cachedKey = nil
        hasHydratedCache = false
        pinnedItemIDs = []
        retainedMisses = [:]
        externalRefreshRevision &+= 1
        let rolls = randomRolls
        Task { await rolls.invalidate() }
    }

    /// Records a live watched/unwatched intent for hero replay, collapsing any
    /// prior intent covering the same target set. This bounds the overlay by the
    /// number of *distinct* titles toggled this session rather than every toggle,
    /// so a long session can't inflate every reconcile fold. Last-write-wins per
    /// target, which is exactly what folding the full history would resolve to.
    func registerWatchMutation(_ mutation: MediaItemMutation) {
        let key = Self.targetKey(for: mutation)
        watchMutations.removeAll { Self.targetKey(for: $0) == key }
        watchMutations.append(mutation)
        if watchMutations.count > Self.maxSessionWatchMutations {
            watchMutations.removeFirst(watchMutations.count - Self.maxSessionWatchMutations)
        }
    }

    private static func targetKey(for mutation: MediaItemMutation) -> String {
        let scoped = mutation.scopedItemIDs.sorted().joined(separator: ",")
        let bare = mutation.itemIDs.sorted().joined(separator: ",")
        return "\(scoped)|\(bare)"
    }
}

@MainActor
@Observable
final class HomeHeroRecedeModel {
    var isReceded = false
}

/// The Home screen: an optional cinematic **hero** carousel followed by
/// Continue Watching, Latest, and library shortcuts.
public struct HomeView: View {
    @State private var viewModel: HomeViewModel
    private var visibility: HomeLibraryVisibilityModel
    private let spoilerSettings: SpoilerSettings
    private let onSelectItem: (MediaItem) -> Void
    private let onPlayItem: (MediaItem) -> Void
    private let onSelectLibrary: (MediaLibrary) -> Void
    /// Servers added to the device, and how many this profile has switched on.
    /// Both are needed to tell "no servers yet" from "all of them turned off".
    private let configuredServerCount: Int
    private let enabledServerCount: Int

    /// Per-profile hero configuration. `nil` (or an inactive config) leaves Home
    /// rendering its classic rows unchanged.
    private var heroSettings: HeroSettingsModel?
    private var heroBackground: HeroBackgroundSettingsModel
    private let heroTrailerController: HeroTrailerController
    /// Lets Home give the media shares a chance to notice new files while the
    /// viewer sits on it. `nil` disables polling (previews, hosts with no shares).
    private let onPollShares: () -> Void
    /// When the viewer last pressed a direction. Tracked on Home's own body,
    /// which IS an ancestor of the focused rails, so it actually sees their moves.
    @State private var lastInteractionAt: ContinuousClock.Instant = .now
    private let heroTrailerResolver: HeroTrailerResolving
    private let heroIsFrontmost: Bool
    private let heroCurator: HeroCurator
    private let heroFeaturedProvider: FeaturedContentProviding
    /// Lightweight Seerr-only status polling. Kept separate from the curated
    /// provider so the 30-second CTA refresh never repeats live watch-state lookups.
    private let heroFeaturedStatusProvider: FeaturedContentProviding
    private let heroRandomProvider: RandomLibraryContentProviding
    private let heroArtworkProvider: HeroArtworkProviding
    /// Confirms a hero candidate's art actually loads before it becomes a slide, so
    /// a title with only a broken/missing backdrop is dropped rather than shown over
    /// the bare app background. Defaults to a real image-load check; tests/previews
    /// can inject a deterministic one.
    private let heroArtworkValidator: HeroArtworkValidating
    /// Re-checks an already-curated set's watch-state without re-fetching or
    /// re-validating it — used by the external-refresh fast path so a warmed identity
    /// index / cross-device watch doesn't trigger a full (multi-second) re-curate.
    /// Defaults to a passthrough (tests + the no-op case); the app injects a bounded
    /// provider watch-state re-enrichment.
    private let heroWatchStateRefresher: @Sendable ([MediaItem]) async -> [MediaItem]
    /// Fills sparse hero list records from their provider's full item endpoint
    /// (notably Plex series certifications) without changing identity/order.
    private let heroMetadataEnricher: @Sendable ([MediaItem]) async -> [MediaItem]
    /// Whether the on-device Home performance HUD is shown (Settings ▸ Diagnostics).
    /// A power-user/debug aid for validating smoothness on older hardware; off by
    /// default and fully inert when off.
    private let homePerfOverlayEnabled: Bool
    /// Live frame/hitch/thermal sampler backing the HUD. Runs only while the
    /// overlay is enabled (started/stopped from the body lifecycle).
    @State private var perfSampler = HomePerfSampler()
    /// Whether Seerr is currently connected — threaded to the hero so a not-owned
    /// featured title only offers a Request CTA when a server is reachable.
    private let heroSeerConnected: Bool
    /// One-tap request for a not-owned featured title (Seerr), threaded to the
    /// hero's Request button. Returns the new availability for an optimistic flip.
    private let onRequestItem: ((MediaItem) async -> MediaAvailabilityStatus?)?
    /// Loads Seerr season-request availability for a featured series, so the home
    /// hero's Request can present a season picker. `nil` disables the picker
    /// (series then request as a whole, like movies).
    private let onRequestAvailability: ((MediaItem) async -> MediaRequestAvailability?)?
    /// Requests the chosen seasons of a featured series from the home hero picker.
    private let onRequestSeasonsItem: ((MediaItem, [Int]) async -> MediaAvailabilityStatus?)?
    /// The app-wide navigation style, so the carousel's left-edge behaviour
    /// (escape to sidebar vs. wrap) matches the surrounding chrome.
    private let navigationStyle: NavigationStyle

    /// Retained above the tab so switching away and back never throws away a
    /// completed curation or its durable/session-local watch overlays.
    private let heroRuntime: HomeHeroRuntimeState

    /// Whether the hero is receded (focus moved down onto the Continue Watching
    /// row). Driven by the page scroll crossing `recedeScrollThreshold` (see
    /// `.onScrollGeometryChange`). When set, the hero's backdrop artwork glides UP
    /// and the content column (logo/buttons/dots) plus the rows below lift toward
    /// the top — the Apple TV recede. Every lift is expressed as a cheap `.offset`
    /// while the rows below remain vertically lazy.
    @State private var heroRecedeModel = HomeHeroRecedeModel()

    /// How long the content/row recede lifts take. Slow and cinematic — the
    /// buttons and paging dots ease up rather than snapping. Because the lifts are
    /// `.offset` transforms (not layout), a long duration costs nothing extra. The
    /// backdrop artwork uses its OWN, even slower curve (see HomeHeroBackdrop) so
    /// it lags behind and settles last — the Apple TV parallax feel.
    private static let recedeAnimationDuration: CGFloat = 0.9

    /// Page-scroll distance (points) past which the hero is considered "receded".
    /// The focus engine scrolls the page ~480pt in a single frame the instant
    /// focus lands on Continue Watching, so any threshold comfortably below that
    /// (and above the few-pixel jitter at rest) flips the recede exactly on a
    /// genuine downward move and clears it when focus scrolls back to the top.
    private static let recedeScrollThreshold: CGFloat = 120

    /// Focus scope spanning the hero + rows; lets the hero's Play button be the
    /// preferred initial focus (see `.focusScope`/`prefersDefaultFocus`).
    @Namespace private var heroFocusScope

    @Environment(\.plozzMetrics) private var metrics

    public init(
        viewModel: HomeViewModel,
        visibility: HomeLibraryVisibilityModel,
        spoilerSettings: SpoilerSettings = .default,
        heroSettings: HeroSettingsModel? = nil,
        heroBackground: HeroBackgroundSettingsModel,
        heroTrailerController: HeroTrailerController,
        onPollShares: @escaping () -> Void = {},
        heroIsFrontmost: Bool,
        heroRuntime: HomeHeroRuntimeState,
        heroCurator: HeroCurator = HeroCurator(),
        heroFeaturedProvider: @escaping FeaturedContentProviding = HeroFeaturedProvider.none,
        heroFeaturedStatusProvider: FeaturedContentProviding? = nil,
        heroRandomProvider: @escaping RandomLibraryContentProviding = HeroRandomProvider.none,
        heroArtworkProvider: @escaping HeroArtworkProviding = { item in
            switch item.kind {
            case .folder, .collection, .unknown:
                return nil
            default:
                return await ArtworkRouter.shared.artworkURL(.hero, for: item)
            }
        },
        heroArtworkValidator: HeroArtworkValidating? = nil,
        heroWatchStateRefresher: @escaping @Sendable ([MediaItem]) async -> [MediaItem] = { $0 },
        heroMetadataEnricher: @escaping @Sendable ([MediaItem]) async -> [MediaItem] = { $0 },
        heroTrailerResolver: @escaping HeroTrailerResolving = { _ in nil },
        homePerfOverlayEnabled: Bool = false,
        seerConnected: Bool = false,
        onRequestItem: ((MediaItem) async -> MediaAvailabilityStatus?)? = nil,
        onRequestAvailability: ((MediaItem) async -> MediaRequestAvailability?)? = nil,
        onRequestSeasonsItem: ((MediaItem, [Int]) async -> MediaAvailabilityStatus?)? = nil,
        navigationStyle: NavigationStyle = .default,
        onSelectItem: @escaping (MediaItem) -> Void,
        onPlayItem: @escaping (MediaItem) -> Void,
        onSelectLibrary: @escaping (MediaLibrary) -> Void,
        configuredServerCount: Int = 1,
        enabledServerCount: Int = 1
    ) {
        _viewModel = State(initialValue: viewModel)
        self.visibility = visibility
        self.spoilerSettings = spoilerSettings
        self.heroSettings = heroSettings
        self.heroBackground = heroBackground
        self.heroTrailerController = heroTrailerController
        self.onPollShares = onPollShares
        self.heroTrailerResolver = heroTrailerResolver
        self.heroIsFrontmost = heroIsFrontmost
        self.heroRuntime = heroRuntime
        self.heroCurator = heroCurator
        self.heroFeaturedProvider = heroFeaturedProvider
        self.heroFeaturedStatusProvider = heroFeaturedStatusProvider ?? heroFeaturedProvider
        self.heroRandomProvider = heroRandomProvider
        self.heroArtworkProvider = heroArtworkProvider
        // Confirm art actually loads (real image fetch/decode, cache-first) unless a
        // test/preview injects a deterministic validator. Set here rather than as a
        // default argument because the public init can't reference the internal
        // `HeroBackdropArtworkPolicy` from a default-argument value.
        self.heroArtworkValidator = heroArtworkValidator ?? { urls in
            await HeroBackdropArtworkPolicy.warmFirstUsablePreview(
                for: urls.map(ArtworkReference.remote)
            )
        }
        self.heroWatchStateRefresher = heroWatchStateRefresher
        self.heroMetadataEnricher = heroMetadataEnricher
        self.homePerfOverlayEnabled = homePerfOverlayEnabled
        self.heroSeerConnected = seerConnected
        self.onRequestItem = onRequestItem
        self.onRequestAvailability = onRequestAvailability
        self.onRequestSeasonsItem = onRequestSeasonsItem
        self.navigationStyle = navigationStyle
        self.onSelectItem = onSelectItem
        self.onPlayItem = onPlayItem
        self.onSelectLibrary = onSelectLibrary
        self.configuredServerCount = configuredServerCount
        self.enabledServerCount = enabledServerCount
        if !heroRuntime.hasHydratedCache {
            heroRuntime.hasHydratedCache = true
            if let settings = heroSettings?.settings,
               let cached = viewModel.cachedHeroItems(for: settings) {
                heroRuntime.cachedKey = HeroConfigurationKey(settings: settings)
                heroRuntime.cachedItems = cached
            }
        }
    }

    public var body: some View {
        let _ = PlozzBodyRate.tick("HomeView")
        return ContentStateView(
            state: viewModel.state,
            emptyMessage: "Your libraries are empty. Add media on your media server to see it here.",
            onRetry: { Task { await viewModel.load() } },
            loadingContent: { HomeSkeletonView(layout: viewModel.skeletonLayout, heroActive: heroSettings?.settings.isActive ?? false, continueWatchingShowsSeriesArtwork: visibility.continueWatchingShowsSeriesArtwork) }
        ) { content in
            // The screen is a data-driven list of rows. Both this loaded view and
            // the skeleton render from the same ordered `HomeRow`/`HomeRowKind`
            // structure, which keeps them 1:1 and makes the order the single thing
            // a future row-customization feature edits. `HomeRow.rows` also applies
            // per-library Home-visibility to *every* row's items (not just the
            // Libraries tiles), so a hidden library's content is suppressed
            // app-wide; passing the reactive `isVisible` here keeps toggles taking
            // effect on the next render even before any re-fetch settles.
            let rows = HomeRow.rows(
                for: content,
                isLibraryVisible: { visibility.isVisible($0) },
                isGlobalRowEnabled: { visibility.visibility.isGlobalRowEnabled($0) }
            )
            let isAwaitingLiveContinueWatching = viewModel.isShowingCachedSnapshot
            let heroContent = HomeHeroLaunchPolicy.content(
                content,
                awaitingLiveContinueWatching: isAwaitingLiveContinueWatching
            )
            let cachedContinueWatchingLayout = HomeRowLayout(
                kind: .continueWatching,
                count: content.continueWatching.isEmpty
                    ? viewModel.skeletonLayout.first(where: {
                        $0.kind == .continueWatching
                    })?.count ?? 0
                    : content.continueWatching.count
            )
            // The descriptor the next launch's skeleton renders from: each row's
            // kind, order *and* how many cards it actually showed, so the skeleton
            // matches a full row and a sparse one alike.
            let layout = rows.map { HomeRowLayout(kind: $0.kind, count: $0.cardCount) }
            let randomLibraries = HeroRandomLibrarySelection.resolve(
                content.libraries,
                settings: heroSettings?.settings,
                isVisible: { visibility.isVisible($0) }
            )
            let heroRecomputeKey = HeroRecomputeKey(
                content: heroContent,
                settings: heroSettings?.settings,
                randomLibraries: randomLibraries,
                externalRefreshRevision: heroRuntime.externalRefreshRevision,
                awaitingLiveHome: viewModel.isShowingCachedSnapshot
            )
            // Seed the hero synchronously from the already-loaded sources
            // (Continue Watching + Watchlist) so it renders in the *same frame* as
            // the rows — no pop-in. Once `recomputeHero` finishes, the retained
            // runtime items (which also include the async Featured/Random sources)
            // take over. See `HomeHeroDisplayResolver` for the full priority order.
            let displayHeroItems = HomeHeroDisplayResolver.resolve(
                runtime: heroRuntime,
                key: heroRecomputeKey,
                settings: heroSettings?.settings,
                continueWatching: heroContent.continueWatching,
                watchlist: heroContent.watchlist,
                recentlyAdded: heroContent.latest,
                curator: heroCurator
            )
            let heroSlotState = HomeHeroSlotState.resolve(
                isConfigured: heroSettings?.settings.isActive ?? false,
                hasItems: !displayHeroItems.isEmpty,
                recomputeComplete: heroRuntime.completedKey == heroRecomputeKey
            )
            let heroActive = heroSlotState == .content
            let heroLayoutActive = heroSlotState != .hidden
            // Account-scoped ids of every watchlisted title, so the hero can show
            // the *series'* watchlist state on an episode/season slide.
            let watchlistedKeys = Set(content.watchlist.map {
                HomeHeroView.watchlistKey(accountID: $0.sourceAccountID, itemID: $0.id)
            })
            // The recede is driven by the page scroll (see
            // `.onScrollGeometryChange`). Going DOWN, the focus engine scrolls the
            // page to reveal Continue Watching and the recede arms itself. Going
            // back UP, though, the hero's action row is still on-screen at that
            // scroll offset, so the focus engine has no reason to scroll back — the
            // page would stay stuck mid-recede. So on focus RETURNING to the hero
            // we programmatically scroll `heroTopID` back to the top (see
            // `onFocusGained`); nothing competes on the way up, so it sticks.
            ScrollViewReader { heroScrollProxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // Kill the Siri Remote **touch-surface pan** so a light touch
                        // (or a resting thumb) can't free-scroll the page out from
                        // under a pinned hero — the "view drifts down even though
                        // focus never moved" bug. tvOS has no `DragGesture` to absorb,
                        // and `.scrollDisabled` would also disable the focus-driven
                        // auto-scroll that reveals lower rows. Instead we reach the
                        // enclosing `UIScrollView` and disable its pan gesture
                        // recognizers: touch-swipe scrolling is driven by the pan,
                        // while focus auto-scroll and `ScrollViewReader.scrollTo` use
                        // `setContentOffset` directly, so navigation and our hero
                        // expand/recede animations keep working. The probe is a real
                        // child of this VStack (not a `.background`) so it is
                        // unambiguously inside the scroll content and its superview
                        // walk reaches the UIScrollView. Gated to the hero layout.
                        #if canImport(UIKit)
                        if heroLayoutActive {
                            ScrollPanDisabler()
                                .frame(width: 1, height: 0)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                        #endif
                        if heroActive, let heroSettings {
                            HomeHeroView(
                                items: displayHeroItems,
                                settings: heroSettings.settings,
                                backgroundSettings: heroBackground.settings,
                                trailerController: heroTrailerController,
                                trailerResolver: heroTrailerResolver,
                                isFrontmost: heroIsFrontmost,
                                spoilerSettings: spoilerSettings,
                                navigationStyle: navigationStyle,
                                watchlistedKeys: watchlistedKeys,
                                focusScope: heroFocusScope,
                                onSelect: onSelectItem,
                                onPlay: onPlayItem,
                                seerConnected: heroSeerConnected,
                                onRequest: onRequestItem,
                                requestAvailability: onRequestAvailability,
                                onRequestSeasons: onRequestSeasonsItem,
                                // When focus returns to the hero from a row below,
                                // un-recede: the content expands back to full-screen
                                // and the backdrop settles back down. A SINGLE flag
                                // drives both; the backdrop's slower timing is a
                                // scoped `.animation` override inside HomeHeroView, so
                                // there's no second `withAnimation` whose state change
                                // could get dropped (the bug where the content
                                // receded but the artwork stayed full-screen).
                                // Recede is driven by the page scroll (see
                                // `.onScrollGeometryChange` below). Focus returning
                                // to the hero must scroll the page back to the top —
                                // the focus engine won't, because the action row is
                                // still visible mid-recede. We clear `heroReceded`
                                // HERE, in the same animation as the scroll-to-top,
                                // so the content un-recedes in PARALLEL with the
                                // return scroll. (If we waited for the scroll to drop
                                // back under the threshold — letting the Bool observer
                                // clear it — the un-recede would only START partway up,
                                // stacking scroll-time + un-recede-time and making the
                                // way UP feel much slower than the way down. The
                                // observer still clears it as a backstop.)
                                onFocusGained: {
                                    withAnimation(.smooth(duration: Self.recedeAnimationDuration)) {
                                        heroRecedeModel.isReceded = false
                                        heroScrollProxy.scrollTo(Self.heroTopID, anchor: .top)
                                    }
                                },
                                onPinnedItemsChanged: { heroRuntime.pinnedItemIDs = $0 },
                                recedeModel: heroRecedeModel
                            )
                            .id(Self.heroTopID)
                            // (touch-pan disabler lives as a sibling below so it is
                            //  unambiguously inside the scroll content — see note.)
                        } else if heroSlotState == .placeholder {
                            // Cached Home rows can paint before Random/Featured hero
                            // curation. Reserve the exact final hero geometry now so
                            // rows never appear "finished" and then jump down seconds
                            // later when the hero arrives.
                            HomeHeroSkeletonView()
                                .id(Self.heroTopID)
                                .contentShape(Rectangle())
                                .focusable(true)
                                .prefersDefaultFocus(true, in: heroFocusScope)
                                .focusEffectDisabled()
                                .accessibilityLabel("Loading featured content")
                        }
                        LazyVStack(alignment: .leading, spacing: metrics.rowSpacing) {
                            // Shown ABOVE the rows, not instead of them. A
                            // watchlist is durable and deliberately
                            // server-independent, so titles saved earlier keep
                            // appearing after every server is switched off — which
                            // makes the silence around them more confusing, not
                            // less. The notice names the setting responsible.
                            //
                            // It is also focusable, which is what keeps the screen
                            // escapable: with everything hidden Home can otherwise
                            // have nothing to focus at all, and on tvOS that
                            // strands the viewer — focus has nowhere to land, the
                            // remote stops responding, and the tab bar back to
                            // Settings can't be reached.
                            if let notice = contentNotice {
                                HomeContentNoticeView(
                                    notice: notice,
                                    onReload: { Task { await viewModel.load() } }
                                )
                            }
                            if isAwaitingLiveContinueWatching {
                                HomeSkeletonRowView(row: cachedContinueWatchingLayout)
                            }
                            if content.mergeLibraries {
                                // Merged: the classic ordered rows (Continue Watching,
                                // Watchlist, Recently Added, Libraries tiles).
                                ForEach(rows.filter {
                                    !isAwaitingLiveContinueWatching
                                        || $0.kind != .continueWatching
                                }) { row in
                                    rowView(row)
                                }
                            } else {
                                // Unmerged: global media rows first, then each library's
                                // opted-in rows, then the Libraries tiles (boxes) last as
                                // the browse entry points — so per-library rows sit with
                                // the global rows and the grid of tiles anchors the foot.
                                ForEach(rows.filter {
                                    $0.kind != .libraries
                                        && (!isAwaitingLiveContinueWatching
                                            || $0.kind != .continueWatching)
                                }) { row in
                                    rowView(row)
                                }
                                ForEach(content.librarySections) { group in
                                    libraryGroupView(group)
                                }
                                if let librariesRow = rows.first(where: { $0.kind == .libraries }) {
                                    rowView(librariesRow)
                                }
                            }
                        }
                        // When the hero is present, pull the rows up so the first row
                        // (Continue Watching) overlaps the hero's lower edge — the
                        // Apple TV look. Otherwise keep the classic top padding. This
                        // padding is STATIC (never animated) — the recede lift is a
                        // separate `.offset` below so it never changes row geometry.
                        // The vertical stack is lazy, so off-screen glass rows stay
                        // unmounted instead of joining every focus-scroll update.
                        .padding(.top, heroLayoutActive
                            ? -Self.heroRowOverlap
                            : PlozzTheme.Metrics.screenVerticalPadding)
                        .padding(.bottom, PlozzTheme.Metrics.screenVerticalPadding)
                        // tvOS focus scrolling already moves Continue Watching into
                        // view; this finishing lift centers it under the receded hero.
                        .modifier(
                            HomeRowsRecedeModifier(
                                active: heroActive,
                                model: heroRecedeModel,
                                lift: Self.recedeRowLift
                            )
                        )
                    }
                    // Span the hero and rows in one focus scope so the hero's
                    // Play button can be the scope's preferred default — tvOS
                    // then lands initial focus on the hero instead of a Continue
                    // Watching card, with no visible focus steal-back.
                    .focusScope(heroFocusScope)
                }
                // Never clip a focused card's lift, shadow or border.
                .scrollClipDisabled()
                // Drive the recede off the SCROLL, observed as a BOOL so this fires
                // ONLY when the threshold is crossed — never on every scroll frame.
                // (The old per-frame CGFloat capture wrote @State each frame, forcing
                // a full HomeView re-evaluation — and thus broad row updates —
                // dozens of times a second: a major cause of the recede
                // stutter.) When focus moves DOWN to a lower row the tvOS focus
                // engine instantly scrolls the page past this threshold in one frame;
                // moving UP to the tab bar or LEFT to the sidebar never scrolls the
                // page down, so the hero only recedes on a genuine downward move —
                // robust where `.onMoveCommand` was not (a Down that relocates focus
                // is consumed by the engine and never delivered to the hero).
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    heroActive && geometry.contentOffset.y > Self.recedeScrollThreshold
                } action: { _, shouldRecede in
                    withAnimation(.smooth(duration: Self.recedeAnimationDuration)) {
                        heroRecedeModel.isReceded = shouldRecede
                    }
                }
                // When the hero is active, let it bleed into the top overscan
                // inset instead of the ScrollView reserving it as a blank bar
                // above the backdrop (the gap that made the hero sit too low).
                // An empty edge set is a no-op, so the classic rows layout keeps
                // its normal top inset under the tab bar.
                .ignoresSafeArea(.container, edges: heroLayoutActive ? .top : [])
            }
            // Remember the structure we actually rendered (post-visibility), keyed
            // on kinds *and* counts so a changed card count re-persists too. Only in
            // merged mode — unmerged rows are dynamic/per-library and must not
            // overwrite the persisted merged skeleton (the loading placeholder stays
            // a sensible generic set; see plan).
            .task(id: layout) { if content.mergeLibraries { viewModel.rememberLayout(layout) } }
            // Recompute the curated hero set whenever Home content or the hero
            // config changes. Off the main actor via the curator's async sources.
            .task(id: heroRecomputeKey) {
                await recomputeHero(
                    content: heroContent,
                    randomLibraries: randomLibraries,
                    key: heroRecomputeKey
                )
            }
            // Live-refresh ONLY the status of featured (Seerr) hero items — their
            // `availability` + `downloadProgress` — folding fresh values onto the
            // existing items in place. Keeps each item's id and the carousel order,
            // so a title flipping Request → Downloading % → Play never resets the
            // hero's current slide, backdrop, paging, dwell, or focus (HomeHeroView
            // only reacts to a change in the items' *ids* — see its id-keyed
            // onChange). Restarts with the recompute baseline; idles when Featured
            // is off or absent.
            .task(id: heroRecomputeKey) {
                await refreshFeaturedStatusLoop()
            }
        }
        .task(id: visibility.visibility) {
            // First appearance loads; thereafter any change to the visibility
            // snapshot — a hidden/disabled library, or the merged↔unmerged flip —
            // re-aggregates so library-scoped providers (Jellyfin) re-fetch with the
            // new visible set and the merged/unmerged layout rebuilds. `loadIfNeeded`
            // skips the reload on a bare reappearance (tvOS restarts this `.task`
            // every time Home returns from a pushed detail), so back-navigation no
            // longer flashes the skeleton or resets focus. Providers that tag items
            // inline (Plex) are also filtered live above, so their toggles feel
            // instant even before the reload settles.
            await viewModel.loadIfNeeded(for: visibility.visibility)
        }
        .onReceive(NotificationCenter.default.publisher(for: .mediaItemDidMutate)) { note in
            if let mutation = MediaItemMutation.from(note) {
                viewModel.applyWatchedState(mutation)
                if mutation.played != nil {
                    heroRuntime.registerWatchMutation(mutation)
                    if shouldRefreshAsyncWatchHistory {
                        heroRuntime.externalRefreshRevision &+= 1
                    }
                }
            } else {
                Task { await viewModel.load() }
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .universalWatchlistDidChange
            )
        ) { _ in
            viewModel.scheduleDurableWatchlistRefresh()
        }
        // New content that lands while the viewer sits on Home appears without a
        // navigation round trip. Zero-size and render-isolated — see the type.
        .onMoveCommand { _ in lastInteractionAt = .now }
        .background(
            HomeShareScanRefreshObserver(
                onRefresh: { Task { await viewModel.load(showLoadingState: false) } },
                isTrailerPlaying: heroTrailerController.isPlaying,
                onPollShares: onPollShares,
                lastInteractionAt: lastInteractionAt
            )
        )
        .onReceive(NotificationCenter.default.publisher(for: .identityIndexDidUpdate)) { _ in
            // The cross-server index warmed further; re-fold the fuller source set
            // into the loaded cards in place so a title that cold-loaded before its
            // local twin was known can now route playback to that local copy. No
            // refetch, and a no-op when no visible card gained a source. Coalesced:
            // the index publishes once per warmed account, so this arrives in a
            // burst on a multi-server boot — debounce to a single fold.
            let refreshAsyncHistory = shouldRefreshAsyncWatchHistory
            viewModel.scheduleReenrich {
                if refreshAsyncHistory {
                    heroRuntime.externalRefreshRevision &+= 1
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if homePerfOverlayEnabled {
                HomePerfOverlay(sampler: perfSampler)
                    .padding(.top, 60)
                    .padding(.trailing, 80)
            }
        }
        .onAppear {
            MainThreadStallProbe.context = "home"
            if homePerfOverlayEnabled || HomePerfDiagnostics.isStdoutMirrorEnabled {
                perfSampler.start()
            }
        }
        .onDisappear { perfSampler.stop() }
        .onChange(of: homePerfOverlayEnabled) { _, enabled in
            if enabled || HomePerfDiagnostics.isStdoutMirrorEnabled {
                perfSampler.start()
            } else {
                perfSampler.stop()
            }
        }
    }

    /// Why Home is sparse, when a SETTING is the reason rather than an empty
    /// library. `nil` when there is nothing to explain.
    ///
    /// The two "nothing is on" cases are told apart deliberately: a viewer who
    /// has never added a server needs a different instruction from one who
    /// switched their servers off, and offering the wrong one sends them looking
    /// in the wrong place.
    private var contentNotice: HomeContentNotice? {
        if configuredServerCount == 0 { return .noServersConfigured }
        if enabledServerCount == 0 { return .allServersSwitchedOff }
        return nil
    }

    private var shouldRefreshAsyncWatchHistory: Bool {
        heroSettings?.settings.requiresExternalWatchHistory ?? false
    }

    /// How far the rows are pulled up so the first row (Continue Watching) peeks
    /// in just below the hero's paging dots — the Apple TV look. Paired with
    /// `HomeHeroView.contentBottomInset` (132): pulling up by slightly less than
    /// that inset lands the Continue Watching title ~40px below the dots, with the
    /// tops of its cards peeking over the hero's lower edge. Tuned on-device. Shared
    /// via ``HomeHeroLayout`` so the loading skeleton pulls its rows up identically.
    private static let heroRowOverlap: CGFloat = HomeHeroLayout.rowOverlap

    /// Extra upward lift applied to the rows when the hero recedes, placing
    /// Continue Watching in its intended centered reading position.
    private static let recedeRowLift: CGFloat = 110

    /// Scroll anchor for the hero, so focus returning to it can snap the scroll
    /// back to the top and re-expand the hero to full-screen.
    private static let heroTopID = "home-hero-top"

    /// Recomputes the curated hero items for the current Home `content` and the
    /// active hero settings, via the injected curator + content seams. Clears the
    /// set when the hero is disabled so Home falls back to its classic layout.
    @MainActor
    private func recomputeHero(
        content: HomeViewModel.Content,
        randomLibraries: [HeroRandomLibrary],
        key: HeroRecomputeKey
    ) async {
        guard HeroRecomputePolicy.shouldRun(
            key: key,
            completedKey: heroRuntime.completedKey
        ) else {
            PlozzLog.boot("HomeHero.curate SKIP unchanged input")
            return
        }
        let started = Date()
        guard let settings = heroSettings?.settings, settings.isActive else {
            heroRuntime.items = []
            heroRuntime.completedKey = key
            return
        }
        if key.awaitingLiveHome, settings.sources != [.featured],
           heroRuntime.items.isEmpty {
            // Nothing curated yet this session and Home is still painting last
            // launch's cached rows. Any hero that includes a local source must be
            // composed from the fresh multi-server aggregate, so wait: curating
            // from cached rows would spend a full pass on an answer the live
            // aggregate is about to replace. The viewer sees last session's hero
            // meanwhile (see `HomeHeroDisplayResolver`), not a skeleton, and the
            // curation folds into it when it lands. Once a curation *has* completed
            // there is nothing left to wait for.
            return
        }

        // External-refresh-only fast path. When the candidate structure is unchanged
        // and only watch history may have moved (a watch mutation / warmed identity
        // index bumped `externalRefreshRevision`), re-check the EXISTING curated
        // items' watch-state instead of re-fetching Seerr/random and re-validating
        // artwork. On-device profiling showed the full re-curate cost 2–8.5s and drove
        // the main-thread hitches while browsing; reusing the loaded set avoids the
        // network re-fetch, the artwork re-decode, and the hero's visual rebuild.
        if let completed = heroRuntime.completedKey,
           completed != key,
           completed.matchesIgnoringExternalRefresh(key),
           !heroRuntime.items.isEmpty {
            let refreshed = await HomePerfDiagnostics.measureCurate {
                await heroWatchStateRefresher(heroRuntime.items)
            }
            guard !Task.isCancelled else { return }
            let durable = await viewModel.pendingHeroWatchMutations()
            heroRuntime.durableWatchMutations = durable
            heroRuntime.hasHydratedDurableMutations = true
            let reconciled = heroCurator.reconcile(
                refreshed,
                settings: settings,
                watchMutations: durable + heroRuntime.watchMutations
            )
            if reconciled != heroRuntime.items { heroRuntime.items = reconciled }
            heroRuntime.completedKey = key
            PlozzLog.boot("HomeHero.curate REFRESH-ONLY items=\(reconciled.count)")
            return
        }

        PlozzLog.boot(
            "HomeHero.curate START max=\(settings.maxItems) sources=\(settings.sources.count)"
        )
        let durableWatchMutations = await viewModel.pendingHeroWatchMutations()
        guard !Task.isCancelled else { return }
        heroRuntime.durableWatchMutations = durableWatchMutations
        heroRuntime.hasHydratedDurableMutations = true
        // The seed's own slides stand in for Seerr while it is unreachable. Only
        // the ones it actually supplied: a watchlist title handed to the Featured
        // source would arrive with no availability and render the wrong CTA.
        let seedMatchesConfiguration =
            heroRuntime.cachedKey == HeroConfigurationKey(settings: settings)
        let cachedFeatured = seedMatchesConfiguration
            ? heroRuntime.cachedItems.filter { $0.availability != nil }
            : []
        // Reuse the Random source's retained draw. Recomputation is triggered by
        // things the viewer never asked for, and re-shuffling every visible library
        // on every connected server for each of them is both the slowest part of a
        // curation and the reason the carousel's contents kept moving on their own.
        let randomRolls = heroRuntime.randomRolls
        let rollKey = HeroRandomRollStore.Key(
            libraries: randomLibraries,
            limit: settings.maxItems,
            hideWatched: settings.hideWatched
        )
        let retainedRandomProvider = heroRandomProvider
        let result = await HomePerfDiagnostics.measureCurate {
            await heroCurator.curateResult(
                settings: settings,
                continueWatching: content.continueWatching,
                watchlist: content.watchlist,
                recentlyAdded: content.latest,
                randomLibraries: randomLibraries,
                watchMutations: durableWatchMutations + heroRuntime.watchMutations,
                featuredProvider: { limit in
                    let fresh = await heroFeaturedProvider(limit)
                    return fresh.isEmpty
                        ? Array(cachedFeatured.prefix(limit))
                        : fresh
                },
                randomProvider: { libraries, limit in
                    await randomRolls.items(for: rollKey) {
                        await retainedRandomProvider(libraries, limit)
                    }
                },
                artworkProvider: heroArtworkProvider,
                artworkValidator: heroArtworkValidator
            )
        }
        let items = result.items
        guard !Task.isCancelled else {
            let elapsedMS = Int(Date().timeIntervalSince(started) * 1_000)
            PlozzLog.boot("HomeHero.curate CANCEL ms=\(elapsedMS)")
            return
        }
        let cacheKey = HeroConfigurationKey(settings: settings)
        if items.isEmpty,
           heroRuntime.cachedKey == cacheKey,
           !heroRuntime.cachedItems.isEmpty {
            // Featured/Random are network sources. A transient empty refresh must
            // not tear down a good launch snapshot; retain it for this session and
            // try again on the next cold launch.
            heroRuntime.completedKey = key
            let elapsedMS = Int(Date().timeIntervalSince(started) * 1_000)
            PlozzLog.boot("HomeHero.curate KEEP-CACHED ms=\(elapsedMS)")
            return
        }
        // Mixed/local heroes stay on their fixed placeholder until presentation
        // metadata—including shared cached ratings—is complete, then publish once.
        // This prevents badges and labels changing underneath the viewer.
        let enriched = await heroMetadataEnricher(items)
        guard !Task.isCancelled else { return }
        let stableItems = heroCurator.deduplicating(enriched)
        // Fold the fresh curation into whatever is already on screen instead of
        // replacing it, so a background refresh the viewer never asked for cannot
        // reshuffle the carousel, wipe the backdrop or move what they were looking
        // at. Titles already showing keep their slot; new media takes spare
        // capacity first and only then the stalest slot that isn't fronted.
        //
        // What is on screen is last session's seed at launch and a curated set
        // thereafter; both fold the same way, which is exactly what lets the seed
        // be shown at all — the slides the viewer can already browse keep their
        // slots instead of being swapped out from under them.
        //
        // Nothing is folded into when the viewer changed the hero's own
        // configuration: that is a direct instruction, the display has already
        // retired the old set (see `HomeHeroDisplayResolver`), and the answer is
        // the fresh curation rather than a reshaped old one.
        let foldsIntoLoadedSet =
            heroRuntime.completedKey?.matchesConfiguration(key) ?? false
        let onScreen = foldsIntoLoadedSet && !heroRuntime.items.isEmpty
            ? heroRuntime.items
            : (seedMatchesConfiguration ? heroRuntime.cachedItems : [])
        let showing = heroCurator.reconcile(
            onScreen,
            settings: settings,
            watchMutations: durableWatchMutations + heroRuntime.watchMutations
        )
        let merge = HeroLiveMerge.merge(
            showing: showing,
            fresh: stableItems,
            limit: settings.maxItems,
            pinnedItemIDs: heroRuntime.pinnedItemIDs,
            misses: foldsIntoLoadedSet ? heroRuntime.retainedMisses : [:],
            freshIsAuthoritative: HeroEmptyCuration.isAuthoritative(
                settings: settings,
                continueWatching: content.continueWatching,
                watchlist: content.watchlist,
                recentlyAdded: content.latest,
                randomLibraries: randomLibraries
            )
        )
        heroRuntime.retainedMisses = merge.misses
        if merge.items != heroRuntime.items { heroRuntime.items = merge.items }
        heroRuntime.cachedItems = []
        heroRuntime.cachedKey = nil
        heroRuntime.completedKey = key
        // Persist what the next launch may repaint instead of a skeleton: the
        // curated set minus its Continue Watching slides, whose resume positions go
        // stale the moment anything is watched anywhere.
        let enrichedByID = Dictionary(
            stableItems.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let enrichedDurable = result.durableItems.map { enrichedByID[$0.id] ?? $0 }
        viewModel.cacheHeroItems(enrichedDurable, for: settings)
        let elapsedMS = Int(Date().timeIntervalSince(started) * 1_000)
        PlozzLog.boot(
            "HomeHero.curate DONE ms=\(elapsedMS) items=\(merge.items.count)"
                + " new=\(merge.admitted.count) retired=\(merge.retired.count)"
        )
    }

    /// Interval between in-place featured-status refreshes while Home is visible.
    /// Matches the cadence order of Overseerr's own download-sync (~1 min); 30s
    /// keeps the CTA responsive without hammering the server.
    private static let featuredRefreshInterval: Duration = .seconds(30)

    /// Periodically re-fetches featured (Seerr) content and folds each fresh
    /// title's `availability` + `downloadProgress` back onto the matching on-screen
    /// hero item **in place**, so the featured CTA tracks the server
    /// (Request → "Downloading n%" → Play) as downloads start and finish.
    ///
    /// Deliberately surgical: it mutates only those two fields on items whose id
    /// still matches a fresh featured result, never changing the array's contents
    /// order or any item's id. That's what guarantees the hero carousel doesn't
    /// re-seat, re-wipe its backdrop, restart its dwell, or move focus — only the
    /// primary button re-derives. Reassigns `heroItems` only when something
    /// actually changed. Idles (re-checking each interval) while the Featured
    /// source is disabled or no featured item is present, so nothing is fetched
    /// needlessly; cancelled automatically when the task is torn down.
    @MainActor
    private func refreshFeaturedStatusLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.featuredRefreshInterval)
            if Task.isCancelled { return }
            guard let settings = heroSettings?.settings, settings.isActive,
                  settings.isEnabled(.featured),
                  heroRuntime.items.contains(where: { $0.availability != nil })
            else { continue }

            let fresh = await heroFeaturedStatusProvider(settings.maxItems)
            if Task.isCancelled { return }
            guard !fresh.isEmpty else { continue }
            var statusByID: [String: (availability: MediaAvailabilityStatus?, progress: Double?)] = [:]
            for item in fresh { statusByID[item.id] = (item.availability, item.downloadProgress) }

            var updated = heroRuntime.items
            var changed = false
            for index in updated.indices {
                guard let status = statusByID[updated[index].id] else { continue }
                if updated[index].availability != status.availability
                    || updated[index].downloadProgress != status.progress {
                    updated[index].availability = status.availability
                    updated[index].downloadProgress = status.progress
                    changed = true
                }
            }
            if changed { heroRuntime.items = updated }
        }
    }

    /// Renders one resolved `HomeRow`. The per-kind wiring (card style, and
    /// whether selecting a card plays it or opens its detail) is exactly what the
    /// view used inline before the row model existed.
    @ViewBuilder
    private func rowView(_ row: HomeRow) -> some View {
        switch row.kind {
        case .continueWatching:
            MediaRowView(title: Text(row.title), items: row.items, style: posterStyle(row.style), spoilerSettings: spoilerSettings, showsSeriesArtwork: visibility.continueWatchingShowsSeriesArtwork, playsOnSelect: true, onSelect: onPlayItem)
        case .watchlist, .recentlyAdded:
            MediaRowView(title: Text(row.title), items: row.items, style: posterStyle(row.style), spoilerSettings: spoilerSettings, onSelect: onSelectItem)
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

    /// Maps a `LibrarySection.Style` (CoreModels) to the concrete card style.
    private func cardStyle(_ style: LibrarySection.Style) -> PosterCardView.Style {
        switch style {
        case .poster: return .poster
        case .landscape: return .landscape
        }
    }

    /// One unmerged library's block: its opted-in rows rendered as normal media
    /// rows, each already titled ("Recently Added in Movies", "More in Drama").
    /// There's no tappable section header — the Libraries tiles below are the
    /// browse entry points into each library's full grid. Poster rows open detail
    /// on select; a landscape row plays — matching the merged rows' behaviour.
    @ViewBuilder
    private func libraryGroupView(_ group: HomeLibrarySectionGroup) -> some View {
        ForEach(group.sections) { section in
            MediaRowView(
                title: Text(verbatim: section.title),
                items: section.items,
                style: cardStyle(section.style),
                spoilerSettings: spoilerSettings,
                playsOnSelect: section.style == .landscape,
                onSelect: section.style == .landscape ? onPlayItem : onSelectItem
            )
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

/// The `.task(id:)` key that drives hero recomputation. It intentionally depends
/// ONLY on the inputs the enabled hero sources actually consume — keyed by item
/// identity plus watch-state fields that affect filtering/presentation, not the
/// full value. View-only settings (auto-advance/trailers) and content backing
/// disabled sources are deliberately excluded. This is important because:
/// keying on the whole `Content` re-ran the recompute on every unrelated content
/// republish (e.g. `latest`/artwork enrichment updating every ~second), and each
/// re-run re-fetched the Random + Featured sources fresh, churning the hero's item
/// ids. That id churn tore down and rebuilt the hero's focusable views — and when
/// a rebuild landed during a tvOS focus transition (e.g. moving up to the tab bar)
/// the focus engine crashed sending `setToViewXFlippedScreenShot:` to the freed
/// view (`NSInvalidArgumentException`). Scoping the key to the real hero inputs
/// stops the needless re-rolls, so the set only changes on genuine, infrequent
/// updates. `Equatable` so SwiftUI restarts the task only on a real curation change.
struct HeroRecomputeKey: Equatable {
    let continueWatching: [HeroCandidateSignature]
    let watchlist: [HeroCandidateSignature]
    let recentlyAdded: [HeroCandidateSignature]
    let randomLibraries: [HeroRandomLibrary]
    let sources: [HeroSourceKind]
    let maxItems: Int
    let hideWatched: Bool
    /// What the viewer chose, separated from what the world supplied. See
    /// ``HeroConfigurationKey``.
    let configuration: HeroConfigurationKey
    let externalRefreshRevision: Int
    let awaitingLiveHome: Bool

    init(
        content: HomeViewModel.Content,
        settings: HeroSettings?,
        randomLibraries: [HeroRandomLibrary],
        externalRefreshRevision: Int = 0,
        awaitingLiveHome: Bool = false
    ) {
        let activeSources = settings?.isActive == true ? settings?.sources ?? [] : []
        self.sources = activeSources
        self.maxItems = activeSources.isEmpty ? 0 : settings?.maxItems ?? 0
        self.hideWatched = activeSources.isEmpty ? false : settings?.hideWatched ?? false
        self.configuration = HeroConfigurationKey(settings: settings)
        let includeSourceIDs = settings?.hideWatched == true
        self.continueWatching = activeSources.contains(.continueWatching)
            ? content.continueWatching.map {
                HeroCandidateSignature($0, includeSourceIDs: includeSourceIDs)
            }
            : []
        self.watchlist = activeSources.contains(.watchlist)
            ? content.watchlist.map {
                HeroCandidateSignature($0, includeSourceIDs: includeSourceIDs)
            }
            : []
        self.recentlyAdded = activeSources.contains(.recentlyAdded)
            ? content.latest.map {
                HeroCandidateSignature($0, includeSourceIDs: includeSourceIDs)
            }
            : []
        self.randomLibraries = activeSources.contains(.randomFromLibrary)
            ? randomLibraries
            : []
        self.externalRefreshRevision = settings?.requiresExternalWatchHistory == true
            ? externalRefreshRevision : 0
        self.awaitingLiveHome = activeSources == [.featured]
            ? false
            : awaitingLiveHome
    }

    /// Whether the loaded candidate set is still structurally valid while only
    /// external watch-history enrichment is being refreshed.
    func matchesIgnoringExternalRefresh(_ other: HeroRecomputeKey) -> Bool {
        continueWatching == other.continueWatching
            && watchlist == other.watchlist
            && recentlyAdded == other.recentlyAdded
            && randomLibraries == other.randomLibraries
            && sources == other.sources
            && maxItems == other.maxItems
            && hideWatched == other.hideWatched
            && awaitingLiveHome == other.awaitingLiveHome
    }

    /// Whether both keys describe the same hero *configuration* — see
    /// ``HeroConfigurationKey``. Content moving through an unchanged configuration
    /// keeps the loaded hero on screen; a configuration change retires it at once.
    func matchesConfiguration(_ other: HeroRecomputeKey) -> Bool {
        configuration == other.configuration
    }
}

struct HeroCandidateSignature: Equatable {
    let accountID: String?
    let id: String
    let isPlayed: Bool
    let hasBeenPlayed: Bool
    let resumePosition: TimeInterval?
    let playedPercentage: Double?
    let sourceIDs: [String]

    init(_ item: MediaItem, includeSourceIDs: Bool = true) {
        accountID = item.sourceAccountID
        id = item.id
        isPlayed = item.isPlayed
        hasBeenPlayed = item.hasBeenPlayed
        resumePosition = item.resumePosition
        playedPercentage = item.playedPercentage
        sourceIDs = includeSourceIDs ? item.sources.map(\.id).sorted() : []
    }
}

/// SwiftUI restarts a view's `.task(id:)` when it reappears even if its id did
/// not change. A NavigationStack push therefore must not be treated as a request
/// to fetch a fresh Random/Featured set; only a genuinely new curation input may
/// replace the completed hero.
enum HeroRecomputePolicy {
    static func shouldRun(
        key: HeroRecomputeKey,
        completedKey: HeroRecomputeKey?
    ) -> Bool {
        completedKey != key
    }
}

/// Resolves the Home hero's structural slot independently from its item details.
/// Loaded rows may be available from disk while async-only hero sources are still
/// curating; that state must reserve the hero geometry with a placeholder rather
/// than briefly rendering the classic rows-only layout.
enum HomeHeroSlotState: Equatable {
    case hidden
    case placeholder
    case content

    static func resolve(
        isConfigured: Bool,
        hasItems: Bool,
        recomputeComplete: Bool
    ) -> HomeHeroSlotState {
        guard isConfigured else { return .hidden }
        if hasItems { return .content }
        return recomputeComplete ? .hidden : .placeholder
    }
}

/// Resolves which hero items to render *this pass* from the retained runtime
/// snapshot, the current recompute key, and the already-loaded page content —
/// pulled out of `HomeView.body` so the (non-trivial) branching is unit-testable
/// in isolation, exactly like ``HomeHeroSlotState/resolve(isConfigured:hasItems:recomputeComplete:)``.
///
/// Priority:
/// 1. **A completed curation keeps rendering while the next one runs.** Home
///    re-curates for reasons the viewer never asked for — a silent
///    re-aggregation, a warmed identity index, a watch mutation, a share scan —
///    and a full re-curation takes seconds. Dropping back to the placeholder for
///    each of those is what made the hero look like it reloaded constantly, most
///    of all with several servers connected. So the loaded set stays on screen,
///    reconciled against the live watch overlays so a just-watched title still
///    drops out, and the fresh curation folds in when it lands (see
///    ``HeroLiveMerge``) rather than replacing what is showing.
///
///    The one thing that *does* retire it immediately is the viewer changing the
///    hero's own configuration — sources, size, Hide Watched, or the Random
///    library selection. That is a direct instruction, and it must be obeyed at
///    once rather than after a re-curation.
/// 2. Otherwise, last session's persisted hero paints instead of a skeleton, so a
///    launch looks like the app was never closed. It holds no Continue Watching
///    slides (see ``HeroCurationResult/durableItems``), because a resume position
///    restored from disk can offer to resume something already finished — the
///    same reason Home does not repaint its cached Continue Watching row. The
///    fresh curation folds into this seed rather than replacing it, so the slides
///    the viewer can already see do not move when it lands.
enum HomeHeroDisplayResolver {
    @MainActor
    static func resolve(
        runtime: HomeHeroRuntimeState,
        key: HeroRecomputeKey,
        settings: HeroSettings?,
        continueWatching: [MediaItem],
        watchlist: [MediaItem],
        recentlyAdded: [MediaItem] = [],
        curator: HeroCurator
    ) -> [MediaItem] {
        let watchMutations = runtime.durableWatchMutations + runtime.watchMutations
        let canReuseLoadedItems = runtime.completedKey?.matchesConfiguration(key) == true
            && !runtime.items.isEmpty
        if canReuseLoadedItems {
            let reconciled = curator.reconcile(
                runtime.items,
                settings: settings,
                watchMutations: watchMutations
            )
            if !reconciled.isEmpty { return reconciled }
        }
        guard let settings,
              runtime.cachedKey == HeroConfigurationKey(settings: settings),
              !runtime.cachedItems.isEmpty else {
            return []
        }
        return curator.reconcile(
            runtime.cachedItems,
            settings: settings,
            watchMutations: watchMutations
        )
    }
}

enum HomeHeroLaunchPolicy {
    static func content(
        _ content: HomeViewModel.Content,
        awaitingLiveContinueWatching: Bool
    ) -> HomeViewModel.Content {
        guard awaitingLiveContinueWatching else { return content }
        var launch = content
        launch.continueWatching = []
        return launch
    }
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

/// Keeps Home current while the viewer sits on it: polls the share catalogs, and
/// reloads when a scan finishes.
///
/// Both halves are needed, and neither works alone. A media-share scan only
/// spawns when something *queries* the catalog, and Home queries once when it
/// loads — so an idle home screen never triggered a scan at all, and a download
/// that finished while the viewer sat there stayed invisible indefinitely, not
/// merely for the ten-minute throttle. `LibraryBrowseView` has reloaded on scan
/// completion for a while; Home never did either.
///
/// Polling is honest here rather than wasteful: an unchanged pass costs a
/// handful of directory listings and a few seconds of background work, and it
/// stops early on its own when nothing moved. The re-query is what spawns the
/// scan; the scanner's own throttle still decides whether a walk actually runs,
/// so this can't cause one to run more often than the interval allows.
///
/// Render-isolated for the same reason as the browse observer: scan and
/// enrichment progress mutate the status dictionary many times a second, and
/// observing that from Home's own body would rebuild every rail on each tick.
/// This view draws nothing, so the invalidation stops here.
///
/// Keyed on the newest completion across all shares rather than one id, since
/// Home aggregates every account.
private struct HomeShareScanRefreshObserver: View {
    /// Silent — the loaded rows stay on screen while fresher ones swap in, so a
    /// background poll never flashes a skeleton or moves focus.
    let onRefresh: () -> Void
    /// Whether a hero trailer is playing. Stillness alone is not idleness: a
    /// viewer watching a trailer sends no move commands for its whole duration,
    /// so the idle window would elapse mid-playback and the reload would tear the
    /// trailer down under them.
    let isTrailerPlaying: Bool
    /// Gives the shares a chance to notice new files. Deliberately separate from
    /// `onRefresh`: polling must cost no UI work, so this pokes the scanner and
    /// nothing else. A reload happens only if that pass reports a real change.
    let onPollShares: () -> Void

    @Environment(ShareScanStatusModel.self) private var status: ShareScanStatusModel?
    @Environment(\.scenePhase) private var scenePhase

    /// Slightly under the scanner's own throttle, so a poll is never the reason a
    /// walk is declined for being too soon.
    private static let pollInterval: Duration = .seconds(120)

    /// When the viewer last moved, supplied by Home itself.
    ///
    /// Deliberately not observed here: this view is a zero-size `.background`, so
    /// it is a *sibling* of the focused rails rather than an ancestor, and
    /// `onMoveCommand` attached to it never sees the moves those rails dispatch.
    /// The gate would then always read as idle — which is how a refresh could land
    /// mid-browse, the exact thing it exists to prevent.
    let lastInteractionAt: ContinuousClock.Instant

    /// Whether content may be swapped in without disturbing the viewer: they have
    /// been still for a while *and* nothing is playing.
    /// A change is waiting for a quiet moment to be shown.
    @State private var hasPendingChange = false

    /// Whether a change time has been seen at all yet.
    ///
    /// The first non-nil observation is the shares telling us what is already on
    /// disk, not news — and Home's own load is fetching exactly that, right now.
    /// Treating it as a change made every cold launch run the whole 5-account
    /// fan-out a second time (measured at 11s of duplicated network and CPU).
    @State private var hasChangeBaseline = false

    /// Whether the app has actually been backgrounded.
    ///
    /// `scenePhase` reaches `.active` during launch too, so refreshing on every
    /// arrival at `.active` reloaded Home moments after it had loaded. Only a
    /// genuine return from background is the "expected reshuffle" moment.
    @State private var hasBeenBackgrounded = false

    /// Show a pending change once nothing is in the way. Called both when a change
    /// arrives and on every poll tick, so a viewer who is mid-browse when new
    /// content lands still sees it as soon as they stop.
    private func refreshIfSafe() {
        guard hasPendingChange, isSafeToRefresh else { return }
        hasPendingChange = false
        onRefresh()
    }

    private var isSafeToRefresh: Bool {
        !isTrailerPlaying && lastInteractionAt.duration(to: .now) >= Self.idleGrace
    }

    /// The newest *change*, not the newest scan. A pass that found nothing must
    /// not move this, or Home reloads on every poll for no reason.
    private var latestChangeAt: Date? {
        status?.byShare.values.compactMap(\.lastChangeAt).max()
    }

    /// Only poll where there is something to poll. A viewer with no media share
    /// gets no timer at all — server-backed accounts report their own changes.
    private var hasShares: Bool { !(status?.byShare.isEmpty ?? true) }

    /// How long the viewer must have been still before a poll may swap content in.
    ///
    /// Reloading Home re-fetches and re-sorts every rail, so rows can reorder
    /// under the cursor mid-browse — content moving while someone is reading it
    /// is worse than seeing it a minute late. A refresh therefore waits for a
    /// quiet moment, which on a living-room screen is the overwhelmingly common
    /// state.
    private static let idleGrace: Duration = .seconds(30)

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: latestChangeAt) { oldValue, newValue in
                guard newValue != nil, newValue != oldValue else { return }
                guard hasChangeBaseline else {
                    // First sighting: this is the state Home is loading anyway.
                    hasChangeBaseline = true
                    return
                }
                // Latched, not dropped. A change arriving while the viewer is
                // busy must not be discarded: `latestChangeAt` won't move again
                // until the *next* real change, and unchanged scans never move
                // it, so returning here left new content invisible indefinitely.
                hasPendingChange = true
                refreshIfSafe()
            }
            .onChange(of: scenePhase) { _, phase in
                // Returning from background is the one moment a visible reshuffle
                // is expected rather than jarring, and the most likely time for
                // something to have arrived. Launch also passes through `.active`,
                // and refreshing there just re-runs the load that is already in
                // flight.
                if phase == .background || phase == .inactive {
                    hasBeenBackgrounded = true
                } else if phase == .active, hasBeenBackgrounded {
                    hasBeenBackgrounded = false
                    onRefresh()
                }
            }
            .task(id: hasShares) {
                guard hasShares else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.pollInterval)
                    guard !Task.isCancelled, scenePhase == .active else { continue }
                    // Never swap content in under an active viewer: wait for the
                    // remote to be still. Re-querying the catalog is what spawns a
                    // scan; the reload then picks up whatever that pass found.
                    // Poking costs nothing on screen, so it needs no idle check —
                    // only the reload that a real change triggers does.
                    onPollShares()
                    // Deliver anything that arrived while the viewer was busy.
                    refreshIfSafe()
                }
            }

            .accessibilityHidden(true)
    }
}

private struct LibraryCardView: View {
    let aggregated: AggregatedLibrary
    let subtitle: String   // l10n:content — library card subtitle from the server
    /// When `true`, the card wears a subtle corner spinner — this library belongs
    /// to a media share that's currently scanning/enriching, so its contents and
    /// artwork are still filling in. Purely decorative (non-focusable).
    var isUpdating: Bool = false
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
                aggregated.library.displayName
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
                title: aggregated.library.displayName,
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
        Group {
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
    }

    /// Themed empty-state for an imageless library: the shared ``ThemePalette/fill``
    /// so it reads as a visible card on every theme, matching the iOS/iPadOS library
    /// tile exactly (same token) and the media-card frame's own rest surface. Opaque
    /// enough that the focus glass halo behind the card can't bleed through, and
    /// focus-independent so nothing jumps on focus.
    /// Empty-state for an imageless library: transparent, so the card's own rest
    /// surface (the shared ``PlozzGlassCardModifier`` `raised` treatment) shows
    /// through and defines the look per theme — a gray lift on Dark, white on Light,
    /// and on OLED/Pure Black just the page-black with a hairline border (no fill).
    /// Only the glyph is drawn on top, so an imageless tile matches the surface
    /// system and the iOS/iPadOS tile exactly.
    private var placeholder: some View {
        ZStack {
            Color.clear
            Image(systemName: librarySymbol)
                .font(.system(size: 64, weight: .semibold))
                .foregroundStyle(palette.tertiaryText)
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

#if canImport(UIKit)
import UIKit

/// A probe view controller that walks up to its enclosing `UIScrollView` and
/// disables every pan gesture recognizer on it, killing Siri Remote
/// touch-surface (swipe) scrolling while leaving focus-driven auto-scroll and
/// `ScrollViewReader.scrollTo` intact (those move content via `setContentOffset`,
/// not the pan).
///
/// Why a `UIViewController` (via `viewDidLayoutSubviews`) rather than a
/// `UIViewRepresentable`: the representable's `updateUIView` only runs when
/// SwiftUI state changes, so a single `DispatchQueue.main.async` superview-walk
/// there can fire *before* the view is attached beneath the scroll view, find
/// nothing, and never retry. `viewDidLayoutSubviews` runs on every layout pass,
/// so it reliably finds the scroll view once attached AND re-asserts the disable
/// if SwiftUI ever re-enables it.
private struct ScrollPanDisabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> ScrollPanDisablerController {
        ScrollPanDisablerController()
    }

    func updateUIViewController(_ controller: ScrollPanDisablerController, context: Context) {}
}

private final class ScrollPanDisablerController: UIViewController {
    private weak var scrollView: UIScrollView?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        disablePan()
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        disablePan()
    }

    private func disablePan() {
        if let scrollView {
            apply(to: scrollView)
            return
        }

        // 1) Preferred: walk up the view hierarchy to the enclosing UIScrollView.
        var ancestor = view.superview
        while let current = ancestor {
            if let found = current as? UIScrollView {
                scrollView = found
                apply(to: found)
                return
            }
            ancestor = current.superview
        }

        // 2) Fallback (in case SwiftUI hosts this probe outside the scroll
        //    content's superview chain): find the vertical page scroll view under
        //    our window and disable it. We identify it as a scroll view whose
        //    content is taller than its bounds and NOT wider (so we never touch
        //    the horizontal card rows, whose contentSize.width exceeds bounds).
        guard let window = view.window else { return }
        if let found = Self.findVerticalScrollView(in: window) {
            scrollView = found
            apply(to: found)
        }
    }

    private func apply(to scrollView: UIScrollView) {
        scrollView.panGestureRecognizer.isEnabled = false
        for recognizer in scrollView.gestureRecognizers ?? [] where recognizer is UIPanGestureRecognizer {
            recognizer.isEnabled = false
        }
    }

    private static func findVerticalScrollView(in root: UIView) -> UIScrollView? {
        if let scrollView = root as? UIScrollView,
           scrollView.contentSize.height > scrollView.bounds.height + 1,
           scrollView.contentSize.width <= scrollView.bounds.width + 1 {
            return scrollView
        }
        for subview in root.subviews {
            if let match = findVerticalScrollView(in: subview) {
                return match
            }
        }
        return nil
    }
}

private struct HomeRowsRecedeModifier: ViewModifier {
    let active: Bool
    let model: HomeHeroRecedeModel
    let lift: CGFloat

    func body(content: Content) -> some View {
        content.offset(y: active && model.isReceded ? -lift : 0)
    }
}

#endif

#endif
