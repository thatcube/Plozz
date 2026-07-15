#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreNetworking
import CoreUI
import MetadataKit

/// Profile-scoped Hero state owned above the transient Home tab subtree. tvOS may
/// recreate a tab's view when switching away and back; retaining the last curated
/// items here prevents loaded content from regressing to a non-focusable skeleton.
@MainActor
@Observable
public final class HomeHeroRuntimeState {
    var items: [MediaItem] = []
    var completedKey: HeroRecomputeKey?
    var externalRefreshRevision = 0
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
    /// (a GPU transform, no relayout) rather than animated layout, so the motion
    /// stays smooth even though the rows are a non-lazy VStack.
    @State private var heroReceded = false

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

    /// App-wide media-share scan/enrich status (optional so previews/tests that
    /// don't inject it don't crash). Drives the "Updating library…" banner.
    @Environment(ShareScanStatusModel.self) private var shareScanStatus: ShareScanStatusModel?

    public init(
        viewModel: HomeViewModel,
        visibility: HomeLibraryVisibilityModel,
        spoilerSettings: SpoilerSettings = .default,
        heroSettings: HeroSettingsModel? = nil,
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
        homePerfOverlayEnabled: Bool = false,
        seerConnected: Bool = false,
        onRequestItem: ((MediaItem) async -> MediaAvailabilityStatus?)? = nil,
        navigationStyle: NavigationStyle = .default,
        onSelectItem: @escaping (MediaItem) -> Void,
        onPlayItem: @escaping (MediaItem) -> Void,
        onSelectLibrary: @escaping (MediaLibrary) -> Void
    ) {
        _viewModel = State(initialValue: viewModel)
        self.visibility = visibility
        self.spoilerSettings = spoilerSettings
        self.heroSettings = heroSettings
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
            await HeroBackdropArtworkPolicy.warmFirstUsablePreview(for: urls)
        }
        self.homePerfOverlayEnabled = homePerfOverlayEnabled
        self.heroSeerConnected = seerConnected
        self.onRequestItem = onRequestItem
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
            loadingContent: { HomeSkeletonView(layout: viewModel.skeletonLayout, heroActive: heroSettings?.settings.isActive ?? false) }
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
                content: content,
                settings: heroSettings?.settings,
                randomLibraries: randomLibraries,
                externalRefreshRevision: heroRuntime.externalRefreshRevision
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
                continueWatching: content.continueWatching,
                watchlist: content.watchlist,
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
                                spoilerSettings: spoilerSettings,
                                navigationStyle: navigationStyle,
                                watchlistedKeys: watchlistedKeys,
                                focusScope: heroFocusScope,
                                onSelect: onSelectItem,
                                onPlay: onPlayItem,
                                seerConnected: heroSeerConnected,
                                onRequest: onRequestItem,
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
                                        heroReceded = false
                                        heroScrollProxy.scrollTo(Self.heroTopID, anchor: .top)
                                    }
                                },
                                receded: heroReceded
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
                        VStack(alignment: .leading, spacing: metrics.rowSpacing) {
                            if content.mergeLibraries {
                                // Merged: the classic ordered rows (Continue Watching,
                                // Watchlist, Recently Added, Libraries tiles).
                                ForEach(rows) { row in
                                    rowView(row)
                                }
                            } else {
                                // Unmerged: global media rows first, then each library's
                                // opted-in rows, then the Libraries tiles (boxes) last as
                                // the browse entry points — so per-library rows sit with
                                // the global rows and the grid of tiles anchors the foot.
                                ForEach(rows.filter { $0.kind != .libraries }) { row in
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
                        // separate `.offset` below so it never triggers a relayout of
                        // the non-lazy rows VStack (the source of the recede stutter).
                        .padding(.top, heroLayoutActive
                            ? -Self.heroRowOverlap
                            : PlozzTheme.Metrics.screenVerticalPadding)
                        .padding(.bottom, PlozzTheme.Metrics.screenVerticalPadding)
                        // Recede lift for the rows, as a cheap transform (no relayout).
                        // Focus does not change during the recede animation (it's
                        // already on Continue Watching), so the focus engine never
                        // re-evaluates scroll mid-lift — the offset is safe.
                        .offset(y: heroActive && heroReceded ? -Self.recedeRowLift : 0)
                    }
                    // Span the hero and rows in one focus scope so the hero's
                    // Play button can be the scope's preferred default — tvOS
                    // then lands initial focus on the hero instead of a Continue
                    // Watching card, with no visible focus steal-back.
                    .focusScope(heroFocusScope)
                    // The share scan/enrich status pill. Lives INSIDE the scroll
                    // content (anchored to the content's top-trailing) so it sits in
                    // the top-right corner and scrolls away with the page — over the
                    // hero on hero pages, above the first row otherwise. Non-focusable
                    // and hit-transparent so it never intercepts focus or taps.
                    .overlay(alignment: .topTrailing) {
                        scanBanner
                            .padding(.trailing, PlozzTheme.Metrics.screenPadding)
                            .padding(.top, heroLayoutActive ? 56 : 12)
                    }
                }
                // Never clip a focused card's lift, shadow or border.
                .scrollClipDisabled()
                // Drive the recede off the SCROLL, observed as a BOOL so this fires
                // ONLY when the threshold is crossed — never on every scroll frame.
                // (The old per-frame CGFloat capture wrote @State each frame, forcing
                // a full HomeView re-evaluation — and thus a relayout of the non-lazy
                // rows — dozens of times a second: a major cause of the recede
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
                        heroReceded = shouldRecede
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
                    content: content,
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

    private var shouldRefreshAsyncWatchHistory: Bool {
        heroSettings?.settings.requiresExternalWatchHistory ?? false
    }

    /// A subtle, non-focusable status pill shown while a media share is scanning or
    /// enriching, so the otherwise-invisible foreground work is legible. Names the
    /// share, its current phase (Scanning / Updating artwork), and live progress
    /// (items found, or "N of M" enriched). Floats over the top-right of the scroll
    /// content (no layout reflow) and scrolls away with the page. Absent when idle.
    @ViewBuilder
    private var scanBanner: some View {
        if let status = shareScanStatus, let primary = status.busyStates.first {
            let multi = status.busyStates.count > 1
            HStack(spacing: 12) {
                // Determinate ring during enrichment (we know N of M); otherwise an
                // indeterminate spinner (the scan total is unknown as it walks).
                if let fraction = primary.enrichFraction, !multi {
                    ProgressView(value: fraction)
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                } else {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(multi ? "\(status.busyStates.count) libraries" : Self.pillTitle(primary))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.primary)
                    if let detail = Self.pillSubtitle(primary, multi: multi) {
                        Text(detail)
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                // The subtitle is padded to a fixed width per pass, so leading-align
                // it and let it keep its own width — nothing reflows as the counter
                // climbs.
                .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.leading, 18)
            .padding(.trailing, 28)
            .padding(.vertical, 10)
            .background(.thinMaterial, in: Capsule())
            .transition(.move(edge: .top).combined(with: .opacity))
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.pillAccessibilityLabel(status))
            // Animate ONLY on structural changes (phase, share, single↔multi), never
            // on each progress tick — otherwise every count update animates the
            // pill's width and it slides side to side. With the fixed-width digits
            // above, count updates don't change the width at all.
            .animation(.easeInOut(duration: 0.25), value: primary.phase)
            .animation(.easeInOut(duration: 0.25), value: primary.name)
            .animation(.easeInOut(duration: 0.25), value: multi)
        }
    }

    /// The pill's bold line: the share being updated (what media).
    private static func pillTitle(_ state: ShareScanState) -> String {
        state.name.isEmpty ? "Media library" : state.name
    }

    /// The pill's secondary line: the current phase plus any live count.
    private static func pillSubtitle(_ state: ShareScanState, multi: Bool) -> String? {
        if multi { return "Updating…" }
        let phase = state.phase
        guard !phase.isEmpty else { return nil }
        if let detail = state.progressDetail { return "\(phase) · \(detail)" }
        return phase
    }

    /// A flattened, spoken description of the pill for VoiceOver.
    private static func pillAccessibilityLabel(_ status: ShareScanStatusModel) -> String {
        let states = status.busyStates
        guard let primary = states.first else { return "" }
        if states.count > 1 { return "Updating \(states.count) libraries" }
        let sub = pillSubtitle(primary, multi: false).map { ", \($0)" } ?? ""
        return "\(pillTitle(primary))\(sub)"
    }

    /// How far the rows are pulled up so the first row (Continue Watching) peeks
    /// in just below the hero's paging dots — the Apple TV look. Paired with
    /// `HomeHeroView.contentBottomInset` (132): pulling up by slightly less than
    /// that inset lands the Continue Watching title ~40px below the dots, with the
    /// tops of its cards peeking over the hero's lower edge. Tuned on-device. Shared
    /// via ``HomeHeroLayout`` so the loading skeleton pulls its rows up identically.
    private static let heroRowOverlap: CGFloat = HomeHeroLayout.rowOverlap

    /// Extra upward lift (points) applied to the rows (Continue Watching et al.)
    /// when the hero is receded, so the row rises a little higher on screen toward
    /// a centered reading position (the artwork having receded above it). Added to
    /// `heroRowOverlap` only while receded and animates with the recede. Row height
    /// is user-variable, so this is a fixed nudge rather than an exact centering.
    /// Tunable.
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
        PlozzLog.boot(
            "HomeHero.curate START max=\(settings.maxItems) sources=\(settings.sources.count)"
        )
        let durableWatchMutations = await viewModel.pendingHeroWatchMutations()
        guard !Task.isCancelled else { return }
        heroRuntime.durableWatchMutations = durableWatchMutations
        heroRuntime.hasHydratedDurableMutations = true
        let items = await HomePerfDiagnostics.measureCurate {
            await heroCurator.curate(
                settings: settings,
                continueWatching: content.continueWatching,
                watchlist: content.watchlist,
                randomLibraries: randomLibraries,
                watchMutations: durableWatchMutations + heroRuntime.watchMutations,
                featuredProvider: heroFeaturedProvider,
                randomProvider: heroRandomProvider,
                artworkProvider: heroArtworkProvider,
                artworkValidator: heroArtworkValidator
            )
        }
        guard !Task.isCancelled else {
            let elapsedMS = Int(Date().timeIntervalSince(started) * 1_000)
            PlozzLog.boot("HomeHero.curate CANCEL ms=\(elapsedMS)")
            return
        }
        heroRuntime.items = items
        heroRuntime.completedKey = key
        let elapsedMS = Int(Date().timeIntervalSince(started) * 1_000)
        PlozzLog.boot("HomeHero.curate DONE ms=\(elapsedMS) items=\(items.count)")
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
                title: section.title,
                items: section.items,
                style: cardStyle(section.style),
                spoilerSettings: spoilerSettings,
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
                            isUpdating: aggregated.providerKind == .mediaShare
                                && (shareScanStatus?.isBusy(shareNamed: aggregated.serverName) ?? false),
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
    let randomLibraries: [HeroRandomLibrary]
    let sources: [HeroSourceKind]
    let maxItems: Int
    let hideWatched: Bool
    let externalRefreshRevision: Int

    init(
        content: HomeViewModel.Content,
        settings: HeroSettings?,
        randomLibraries: [HeroRandomLibrary],
        externalRefreshRevision: Int = 0
    ) {
        let activeSources = settings?.isActive == true ? settings?.sources ?? [] : []
        self.sources = activeSources
        self.maxItems = activeSources.isEmpty ? 0 : settings?.maxItems ?? 0
        self.hideWatched = activeSources.isEmpty ? false : settings?.hideWatched ?? false
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
        self.randomLibraries = activeSources.contains(.randomFromLibrary)
            ? randomLibraries
            : []
        self.externalRefreshRevision = settings?.requiresExternalWatchHistory == true
            ? externalRefreshRevision : 0
    }

    /// Whether the loaded candidate set is still structurally valid while only
    /// external watch-history enrichment is being refreshed.
    func matchesIgnoringExternalRefresh(_ other: HeroRecomputeKey) -> Bool {
        continueWatching == other.continueWatching
            && watchlist == other.watchlist
            && randomLibraries == other.randomLibraries
            && sources == other.sources
            && maxItems == other.maxItems
            && hideWatched == other.hideWatched
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

/// Resolves the Random source's persisted library selection against Home's already
/// loaded catalog. An empty selection means every currently visible library; an
/// explicit selection remains independent from Home row visibility, matching the
/// existing settings behavior.
enum HeroRandomLibrarySelection {
    static func resolve(
        _ libraries: [AggregatedLibrary],
        settings: HeroSettings?,
        isVisible: (String) -> Bool
    ) -> [HeroRandomLibrary] {
        guard let settings,
              settings.isActive,
              settings.isEnabled(.randomFromLibrary)
        else {
            return []
        }

        let configuredKeys = settings.randomLibraryKeys
        return libraries.compactMap { library in
            guard library.library.kind == .movie || library.library.kind == .series else {
                return nil
            }
            let selected = configuredKeys.isEmpty
                ? isVisible(library.key)
                : configuredKeys.contains(library.key)
            guard selected else { return nil }
            return HeroRandomLibrary(
                accountID: library.accountID,
                libraryID: library.library.id,
                kind: library.library.kind
            )
        }
        .sorted {
            ($0.accountID, $0.libraryID) < ($1.accountID, $1.libraryID)
        }
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
/// 1. If the runtime holds items for the current key — or one that differs only
///    by an in-flight external-history refresh — reconcile them against the live
///    watch overlays and show those. This keeps the async Featured/Random slides
///    and preserves focus while a just-watched title still drops out.
/// 2. Otherwise seed synchronously from the already-loaded Continue Watching +
///    Watchlist sources so the hero renders in the same frame as the rows — but
///    hold that seed back until durable (offline) watch intents have hydrated when
///    Hide Watched is on, so a seen title can't flash in before it's filtered.
enum HomeHeroDisplayResolver {
    @MainActor
    static func resolve(
        runtime: HomeHeroRuntimeState,
        key: HeroRecomputeKey,
        settings: HeroSettings?,
        continueWatching: [MediaItem],
        watchlist: [MediaItem],
        curator: HeroCurator
    ) -> [MediaItem] {
        let watchMutations = runtime.durableWatchMutations + runtime.watchMutations
        let hasCurrentAsyncItems = runtime.completedKey == key && !runtime.items.isEmpty
        let canReuseLoadedItems = runtime.completedKey?.matchesIgnoringExternalRefresh(key) == true
            && !runtime.items.isEmpty
        if hasCurrentAsyncItems || canReuseLoadedItems {
            let reconciled = curator.reconcile(
                runtime.items,
                settings: settings,
                watchMutations: watchMutations
            )
            if !reconciled.isEmpty { return reconciled }
        }
        let durableReplayReady = settings?.hideWatched != true
            || runtime.hasHydratedDurableMutations
        guard durableReplayReady else { return [] }
        return settings.map {
            curator.curateSync(
                settings: $0,
                continueWatching: continueWatching,
                watchlist: watchlist,
                watchMutations: watchMutations
            )
        } ?? []
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
private struct LibraryCardView: View {
    let aggregated: AggregatedLibrary
    let subtitle: String
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
        // A media share still filling in shows a spinner CENTERED in the tile —
        // right where the library glyph would sit (the glyph is hidden while
        // updating, see `placeholder`) — a quiet "this is updating" hint that
        // matches the Home status pill, without a repetitive text label on each card.
        .overlay {
            if isUpdating {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.large)
                    .scaleEffect(1.1)
                    .tint(palette.secondaryText.opacity(0.7))
                    .transition(.opacity)
                    .accessibilityHidden(true)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: isUpdating)
    }

    /// Themed empty-state for an imageless library. A subtle vertical gradient
    /// between the page's `backgroundBase` (top) and the opaque `cardOpaqueSurface`
    /// (bottom): close in value so the fill reads a touch brighter than the page
    /// yet never as a heavy gradient, and — because both stops come straight from
    /// the palette — it tracks light / dark and collapses to pure black in Pure Black
    /// (both stops are black there). Opaque, so the focus glass halo behind the
    /// card can't bleed through, and focus-independent so nothing jumps on focus.
    private var placeholder: some View {
        ZStack {
            LinearGradient(
                colors: [palette.backgroundBase, palette.cardOpaqueSurface],
                startPoint: .top,
                endPoint: .bottom
            )
            // The centered updating spinner takes the glyph's place, so hide the
            // glyph while a share is updating (see `artwork`'s centered overlay).
            if !isUpdating {
                Image(systemName: librarySymbol)
                    .font(.system(size: 64, weight: .semibold))
                    .foregroundStyle(palette.secondaryText.opacity(0.4))
            }
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
#endif

#endif
