#if canImport(SwiftUI)
import CoreNetworking
import SwiftUI
import CoreModels
import CoreUI
import FeatureHomeCore
#if canImport(UIKit)
import UIKit
#endif

/// Item detail screen: backdrop hero, metadata, Play/Resume, and children.
public struct ItemDetailView: View {
    @State private var viewModel: ItemDetailViewModel
    private let spoilerSettings: SpoilerSettings
    private let onPlay: (MediaItem) -> Void
    private let onSelectChild: (MediaItem) -> Void
    /// Routes a context-menu navigation action ("Episode Info", "Go to Season")
    /// to this page's own navigation stack.
    ///
    /// Passed in rather than read from `Environment`: a `navigationDestination`
    /// destination does not inherit environment installed on the stack that owns
    /// it, so an environment-based router is silently nil on every pushed page —
    /// which dropped these actions from every menu inside a detail page while
    /// they kept working on the stack's root content.
    private let onNavigate: ((MediaItem) -> Void)?
    /// Opens a cast member, told which account the *loaded* detail came from.
    ///
    /// The account has to be bound here rather than by the host, because only the
    /// loaded detail knows its real source: the item a host pushes with is a seed
    /// (and for a cross-server merged title may name no account at all), whereas
    /// the cast on screen belongs to whichever server actually answered.
    private let onSelectPerson: ((MediaPerson, String?) -> Void)?
    /// Detail-page depth for this navigation stack. Passed in for the same reason
    /// as `onNavigate`: a `navigationDestination` destination does not inherit
    /// environment installed on the stack that owns it.
    private let stackDepth: DetailStackDepth?
    /// This page's own level on the stack, recorded once it has appeared.
    @State private var ownStackDepth: Int?
    /// Fast/local trailer resolver. A nil result leaves the static detail hero;
    /// online YouTube autoplay remains deliberately out of the first version.
    private let heroTrailerResolver: HeroTrailerResolving
    /// Home-pushed details return to a hero that may reclaim the same shared
    /// player. Other entry points (Search, library-only flows) stop on disappear.
    private let preservesHeroTrailerOnDisappear: Bool
    /// Whether the opened item is a not-in-library **discovery** (Seerr) title.
    /// When `true` the page renders a request-focused hero (no children rail,
    /// server/version pickers, watchlist/watched actions) instead of the library
    /// detail layout, and a season/series discovery title is NOT routed into
    /// `SeriesDetailView` (which expects real library seasons/episodes).
    private let isDiscoveryItem: Bool
    /// Whether Seerr is currently connected — gates the discovery Request pill.
    private let seerConnected: Bool
    /// One-tap Seerr request for a not-in-library discovery title. Returns a
    /// provider-agnostic ``MediaRequestActionResult`` — a status on success (the
    /// pill flips to Requested/Downloading), or a user-facing failure the page
    /// surfaces as an alert. Only used on the discovery page.
    private let onRequest: ((MediaItem) async -> MediaRequestActionResult)?
    /// Season-level Seerr coverage for a normal playable library series.
    private let requestAvailabilityRefresh: (@Sendable (MediaItem) async -> MediaRequestAvailability?)?
    /// Requests explicit season numbers for a playable library series.
    private let onRequestSeasons: ((MediaItem, [Int]) async -> MediaRequestActionResult)?
    /// Display name of the Seerr user the active profile requests as, when mapped.
    /// Drives the "Request as <name>" pill so a shared-TV request's identity is
    /// visible **before** the press. `nil` = requests run as admin.
    private let requestActingName: String?
    /// Whether requesting as **admin** (unmapped) should show a confirm step
    /// first — used in a multi-profile household so a member on an unmapped
    /// profile doesn't silently one-tap-request (and possibly auto-approve) as the
    /// unrestricted admin.
    private let confirmAdminRequest: Bool
    /// When this detail is a series opened via "Go to Season", the season to
    /// pre-select on the series page. Ignored for non-series items.
    private let initialSeasonID: String?
    /// When a series is opened by tapping one of its episodes (rather than the
    /// series itself), the tapped episode. The series page then opens with this
    /// episode fronted in the hero (Play targets it), its season selected, the
    /// episode row pre-scrolled to it, and focus on the hero Play button.
    private let initialEpisode: MediaItem?
    /// Lands initial focus on the hero Play button (top) rather than letting tvOS
    /// pick a bottom-anchored control in the full-screen hero — which would make
    /// it auto-scroll the page down on arrival. Mirrors `SeriesDetailView`.
    @FocusState private var playFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @FocusState private var emptyBackFocused: Bool

    /// This device's capabilities, used only as a conservative ordering hint for
    /// the smart default version/server. Actual delivery is resolved at play time.
    private let capabilities: MediaCapabilities
    /// Persists the user's per-title preferred version (creative addition), so a
    /// title reopens on the version they last chose rather than the default.
    private let versionPreferences: VersionPreferenceStoring
    /// The user's explicit version override for this visit. `nil` means "use the
    /// remembered preference, else the smart recommended default".
    @State private var versionOverride: String?
    /// The user's explicit server override for this visit (an `Account.id`). `nil`
    /// means "use the cross-server best-source default". Cleared sources reset it.
    @State private var sourceOverride: String?
    /// Optimistic availability override applied the instant the user taps Request
    /// on a discovery title, so the pill flips to Requested/Downloading without
    /// waiting for the next fetch; reconciled with the server's returned status
    /// (or cleared on failure so Request returns for a retry). Mirrors the Home
    /// hero's `requestOverrides` pattern.
    @State private var requestOverride: MediaAvailabilityStatus?
    /// A pending request failure to surface as an alert (title + optional message),
    /// set from the ``MediaRequestActionResult`` when a request is rejected.
    @State private var requestFailure: RequestFailureAlert?
    /// Drives the "Request as Admin?" confirmation dialog for the unmapped case.
    @State private var showingAdminConfirm = false
    @State private var pendingAdminRequest: PendingRequestIntent?
    @State private var seasonRequestAvailability: MediaRequestAvailability?
    @State private var seasonRequestAvailabilityResolved = false
    @State private var seasonRequestAvailabilityFailed = false
    @State private var seasonRequestRetryToken = 0
    @State private var isSeasonRequestInFlight = false
    /// One-time acknowledgement of the "requests as unrestricted admin" explainer.
    /// Device-wide (shared with any other request surface via this key): once the
    /// user has confirmed an admin request once, we don't nag on every subsequent
    /// request — intentionally requesting as admin is a legitimate choice. Mapping
    /// a profile to a Seerr user avoids the admin path (and this prompt) entirely.
    @AppStorage("seerr.adminRequestAcknowledged") private var adminRequestAcknowledged = false
    @Environment(HeroTrailerController.self) private var heroTrailerController
    @Environment(HeroBackgroundSettingsModel.self) private var heroBackground

    /// A user-facing request failure, wrapped for `.alert(item:)`.
    private struct RequestFailureAlert: Identifiable {
        let id = UUID()
        let title: LocalizedStringResource
        let message: MediaRequestActionResult.FailureMessage?
    }

    private struct PendingRequestIntent {
        let item: MediaItem
        let seasons: [Int]?
    }

    public init(
        viewModel: ItemDetailViewModel,
        spoilerSettings: SpoilerSettings = .default,
        onPlay: @escaping (MediaItem) -> Void,
        onSelectChild: @escaping (MediaItem) -> Void,
        onNavigate: ((MediaItem) -> Void)? = nil,
        onSelectPerson: ((MediaPerson, String?) -> Void)? = nil,
        stackDepth: DetailStackDepth? = nil,
        heroTrailerResolver: @escaping HeroTrailerResolving = { _ in nil },
        preservesHeroTrailerOnDisappear: Bool = false,
        initialSeasonID: String? = nil,
        initialEpisode: MediaItem? = nil,
        isDiscoveryItem: Bool = false,
        seerConnected: Bool = false,
        onRequest: ((MediaItem) async -> MediaRequestActionResult)? = nil,
        requestAvailabilityRefresh: (@Sendable (MediaItem) async -> MediaRequestAvailability?)? = nil,
        onRequestSeasons: ((MediaItem, [Int]) async -> MediaRequestActionResult)? = nil,
        requestActingName: String? = nil,
        confirmAdminRequest: Bool = false,
        capabilities: MediaCapabilities = .detected(),
        versionPreferences: VersionPreferenceStoring = VersionPreferenceStore()
    ) {
        _viewModel = State(initialValue: viewModel)
        self.spoilerSettings = spoilerSettings
        self.onPlay = onPlay
        self.onSelectChild = onSelectChild
        self.onNavigate = onNavigate
        self.onSelectPerson = onSelectPerson
        self.stackDepth = stackDepth
        self.heroTrailerResolver = heroTrailerResolver
        self.preservesHeroTrailerOnDisappear = preservesHeroTrailerOnDisappear
        self.initialSeasonID = initialSeasonID
        self.initialEpisode = initialEpisode
        self.isDiscoveryItem = isDiscoveryItem
        self.seerConnected = seerConnected
        self.onRequest = onRequest
        self.requestAvailabilityRefresh = requestAvailabilityRefresh
        self.onRequestSeasons = onRequestSeasons
        self.requestActingName = requestActingName
        self.confirmAdminRequest = confirmAdminRequest
        self.capabilities = capabilities
        self.versionPreferences = versionPreferences
    }

    public var body: some View {
        let _ = plozzPrintChanges { Self._printChanges() }
        let _ = PlozzBodyRate.tick("ItemDetail")
        ContentStateView(
            state: viewModel.state,
            onRetry: { Task { await viewModel.load() } }
        ) { detail in
            // A season never has its own page: ItemDetailViewModel transparently
            // redirects a season load to its parent series, so by the time we
            // render here a season has become a `.series`. `container` only ever
            // serves movies, episodes, folders and collections.
            if isShed {
                // Buried under two or more pages: build nothing. Keeps this page's
                // artwork out of memory and its subtree out of every diff pass,
                // while the surrounding modifiers (`.task`, the DetailStackDepth
                // bookkeeping in `.onAppear`/`.onDisappear`) stay attached and
                // unaffected — so the page re-inflates in place when uncovered.
                Color.clear
            } else if isDiscoveryItem {
                // A not-in-library discovery title (movie OR series) has no library
                // children/sources to render, and must NOT enter SeriesDetailView
                // (which expects real seasons/episodes). Show a request-focused
                // hero built from the seeded TMDB metadata.
                discoveryDetail(detail)
            } else if detail.item.kind == .series {
                SeriesDetailView(
                    series: detail.item,
                    hasChildOnTop: hasChildOnTop,
                    seasons: detail.children.filter { $0.kind == .season },
                    looseEpisodes: detail.children.filter { $0.kind == .episode },
                    viewModel: viewModel,
                    spoilerSettings: spoilerSettings,
                    onPlay: onPlay,
                    requestAvailability: seasonRequestAvailability?.markingAvailable(
                        detail.children.compactMap { child in
                            child.kind == .season || child.kind == .episode ? child.seasonNumber : nil
                        }
                    ),
                    isRequestingSeasons: isSeasonRequestInFlight,
                    onRequestSeasons: onRequestSeasons == nil ? nil : { seasons in
                        requestTapped(detail.item, seasons: seasons)
                    },
                    onSelectServer: { source in
                        // Switch to the chosen server's copy of this show IN PLACE
                        // (reload its seasons/episodes) rather than pushing a new
                        // page — so the cross-server picker doesn't grow the back
                        // stack. SeriesDetailView preserves the fronted episode by
                        // its season+episode NUMBER across the switch (per-server
                        // ids differ). Movies already switch in place via state
                        // override; this brings series to parity.
                        Task { await viewModel.switchToSource(accountID: source.accountID) }
                    },
                    onSelectRelated: onSelectChild,
                    initialSeasonID: initialSeasonID ?? viewModel.preselectedSeasonID ?? initialEpisode?.seasonID,
                    initialEpisode: initialEpisode,
                    capabilities: capabilities,
                    versionPreferences: versionPreferences
                )
            } else if isEmptyContainer(detail) {
                emptyFolderState(detail.item)
            } else if isLoadingContainer(detail) {
                // A folder/collection whose children haven't arrived yet has NO
                // focusable element in `container` (no Play button, no rail, no
                // picker) — on tvOS that makes Menu quit the app. Show a focusable
                // loading placeholder for the whole fetch so Back always works.
                loadingFolderState(detail.item)
            } else {
                container(detail)
            }
        }
        // Detail is a full-screen sub-page: hide the top tab bar.
        .toolbar(.hidden, for: .tabBar)
        // Always run load(), even when the page was seeded with the tapped list
        // item for instant first paint. The seed only paints a hero; load() must
        // still fetch the full detail AND its children (seasons/episodes). Skipping
        // it for seeded opens stranded series pages with no seasons/episodes/Play
        // button. load() guards against flashing `.loading` over a seeded hero.
        .task { await viewModel.load() }
        .onDisappear {
            viewModel.suspendEnrichment()
            let itemID = viewModel.state.value?.item.id
            if let itemID {
                heroTrailerController.clearEndHandler(ownerID: "detail-\(itemID)")
                if !preservesHeroTrailerOnDisappear {
                    heroTrailerController.stop(ifShowing: itemID)
                }
            }
        }
        .onAppear {
            MainThreadStallProbe.context = "detail"
            viewModel.resumeEnrichmentIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .mediaItemDidMutate)) { note in
            if let mutation = MediaItemMutation.from(note) {
                viewModel.applyWatchedState(mutation)
            } else {
                Task { await viewModel.reload() }
            }
        }
        .task(id: seasonRequestRefreshKey) {
            await refreshSeasonRequestAvailability()
        }
        .task(id: heroTrailerTaskID) {
            guard heroBackground.settings.detailMode == .trailer,
                  let item = viewModel.state.value?.item else { return }
            if let currentID = heroTrailerController.currentItemID,
               currentID != item.id {
                heroTrailerController.stop()
            }
            // Detail owns end-of-item while it is frontmost. This replaces Home's
            // page-advance callback so the hidden carousel cannot start a
            // different title behind this detail page.
            heroTrailerController.setEndHandler(ownerID: "detail-\(item.id)") {
                heroTrailerController.stop()
            }
            // Home→detail continuity: if the shared controller already has this
            // item, do nothing — the picture keeps rolling (and keeps its live
            // session mute) while metadata swaps.
            guard !heroTrailerController.isShowing(item.id) else {
                heroTrailerController.setPaused(false)
                return
            }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            guard let source = await heroTrailerResolver(item),
                  !Task.isCancelled,
                  viewModel.state.value?.item.id == item.id else { return }
            heroTrailerController.play(
                itemID: item.id,
                resolvedURL: source.url,
                muted: heroBackground.settings.detailTrailerMuted
            )
        }
        .confirmationDialog(
            "Request as Admin?",
            isPresented: $showingAdminConfirm,
            titleVisibility: .visible
        ) {
            Button("Request as Admin") {
                adminRequestAcknowledged = true
                if let pendingAdminRequest {
                    performRequest(pendingAdminRequest)
                }
                pendingAdminRequest = nil
            }
            Button("Cancel", role: .cancel) {
                pendingAdminRequest = nil
            }
        } message: {
            Text("This profile isn’t linked to a Seerr user, so the request is made as the unrestricted admin. Link a user in Settings to track requests per person.")
        }
        .alert(item: $requestFailure) { failure in
            Alert(
                title: Text(failure.title),
                message: failure.message.map { detail in
                    switch detail {
                    case let .copy(resource): Text(resource)
                    case let .serverText(text): Text(verbatim: text)
                    }
                },
                dismissButton: .default(Text("OK"))
            )
        }
        #if canImport(AVFoundation)
        .themeMusicPlayback(
            playbackID: viewModel.themeMusicPlaybackID,
            resolve: { await viewModel.resolveThemeMusic() }
        )
        #endif
        // Overrides rather than replaces, so a caller that supplies no router
        // leaves any inherited one intact.
        .transformEnvironment(\.mediaItemNavigator) { navigator in
            if let onNavigate { navigator = onNavigate }
        }
        // A push does not disappear the page beneath it, so a page can only learn
        // it has been covered from the *child's* lifecycle — see DetailStackDepth.
        // The level is recorded here, after incrementing, because a child view's
        // `onAppear` runs BEFORE this one and would capture the pre-push value.
        .onAppear {
            stackDepth?.pageAppeared()
            if ownStackDepth == nil { ownStackDepth = stackDepth?.depth }
        }
        .onDisappear { stackDepth?.pageDismissed() }
        // Bound from the loaded detail, which is the only thing that knows which
        // server answered for this title — and therefore whose person ids the
        // cast list holds.
        .mediaPersonNavigator { person in
            onSelectPerson?(person, viewModel.state.value?.item.sourceAccountID)
        }
    }

    private var heroTrailerTaskID: String {
        let itemID = viewModel.state.value?.item.id ?? "-"
        return "\(itemID)|\(heroBackground.settings.detailMode.rawValue)"
    }

    /// Layout for non-series detail: a hero plus, for seasons/folders/collections,
    /// a single rail of children. Movies and episodes show just the hero + Play.
    private static let topAnchorID = "item-hero-top"

    /// The detail page for a not-in-library discovery (Seerr) title: a full-screen
    /// hero built entirely from the seeded TMDB metadata (poster/backdrop/overview)
    /// with a single Request / Requested / Downloading pill. There is no children
    /// rail, server/version picker, or watchlist/watched action — none apply to a
    /// title that isn't in any library.
    private func discoveryDetail(_ detail: ItemDetailViewModel.Detail) -> some View {
        let effectiveAvailability = requestOverride ?? detail.item.availability
        let cta = MediaItem.heroCTA(
            availability: effectiveAvailability,
            downloadProgress: detail.item.downloadProgress,
            seerConnected: seerConnected
        )
        // TEMPORARY (issue: a discovery title that turns out to be owned shows no
        // buttons at all) — kept while the fix is watched on device.
        //
        // Keyed to the STATE, never emitted from the body. Written inline first,
        // it fired on every render pass, and this page can re-render in a tight
        // loop — so three synchronous writes (os_log, stdout, file) per pass ran
        // thousands of times on the main thread and turned a re-render churn into
        // a jetsam kill. Telemetry must never be a side effect of `body`.
        let discoveryTraceKey = "\(detail.item.id)|\(cta)|\(String(describing: effectiveAvailability))"
        return ScrollView {
            DetailHeroView(
                item: detail.item,
                heroHeightFraction: 1.0,
                spoilerSettings: spoilerSettings,
                playTitle: nil,
                onPlay: nil,
                isDiscoveryItem: true,
                requestCTA: cta,
                // Show "Request as <name>" before the press so a shared-TV
                // request's identity is visible up front.
                requestActingName: requestActingName,
                onRequest: (detail.item.kind == .movie && onRequest != nil && cta == .request)
                    ? { requestTapped(detail.item) }
                    : nil,
                seasonRequestAvailability: detail.item.kind == .series ? seasonRequestAvailability : nil,
                seasonRequestAvailabilityResolved: seasonRequestAvailabilityResolved,
                seasonRequestAvailabilityFailed: seasonRequestAvailabilityFailed,
                isRequestingSeasons: isSeasonRequestInFlight,
                onRequestSeasons: onRequestSeasons == nil ? nil : { seasons in
                    requestTapped(detail.item, seasons: seasons)
                },
                onRetrySeasonRequestAvailability: {
                    seasonRequestRetryToken &+= 1
                }
            )
            .id(Self.topAnchorID)
        }
        // Never clip the focused request pill's lift/shadow.
        .scrollClipDisabled()
        // Fires once per distinct state rather than once per render — see
        // `discoveryTraceKey`.
        .task(id: discoveryTraceKey) {
            PersonDiagnostics.emit(
                "detail.discovery title=\(detail.item.title) seer=\(seerConnected) "
                + "availability=\(String(describing: effectiveAvailability)) cta=\(cta) "
                + "tmdb=\(detail.item.providerIDs["Tmdb"] ?? "-") id=\(detail.item.id)"
            )
        }
    }

    /// Handles a Request tap: confirm ONCE for the unmapped admin case in a
    /// household (see `confirmAdminRequest`) so a member on an unmapped profile is
    /// told their request goes as the unrestricted admin — but only until they've
    /// acknowledged it once (intentional admin use shouldn't nag every time).
    /// Mapped requests, and everything after the one-time acknowledgement, fire
    /// directly.
    private func requestTapped(_ item: MediaItem, seasons: [Int]? = nil) {
        let intent = PendingRequestIntent(item: item, seasons: seasons)
        if confirmAdminRequest && requestActingName == nil && !adminRequestAcknowledged {
            pendingAdminRequest = intent
            showingAdminConfirm = true
        } else {
            performRequest(intent)
        }
    }

    /// Sends a one-tap Seerr request for a discovery title, optimistically flipping
    /// the pill to Requested/Downloading immediately, then reconciling with the
    /// returned result: a success keeps the new status; a failure clears the
    /// optimistic override (so Request returns for a retry) and surfaces an alert.
    private func performRequest(_ intent: PendingRequestIntent) {
        if let seasons = intent.seasons {
            performSeasonRequest(intent.item, seasons: seasons)
            return
        }
        guard let onRequest else { return }
        requestOverride = .pending
        Task {
            let result = await onRequest(intent.item)
            if let status = result.status {
                requestOverride = status
            } else {
                requestOverride = nil
                if let title = result.failureTitle {
                    requestFailure = RequestFailureAlert(title: title, message: result.failureMessage)
                }
            }
        }
    }

    private func performSeasonRequest(_ item: MediaItem, seasons: [Int]) {
        guard let onRequestSeasons, !seasons.isEmpty, !isSeasonRequestInFlight else { return }
        let previous = seasonRequestAvailability
        seasonRequestAvailability = previous?.markingRequested(seasons)
        isSeasonRequestInFlight = true
        Task {
            let result = await onRequestSeasons(item, seasons)
            if !result.isSuccess {
                seasonRequestAvailability = previous
            }
            isSeasonRequestInFlight = false
            if let title = result.failureTitle {
                requestFailure = RequestFailureAlert(title: title, message: result.failureMessage)
            }
        }
    }

    private var seasonRequestRefreshKey: String {
        guard seerConnected,
              let item = viewModel.state.value?.item,
              item.kind == .series,
              item.providerIDs["Tmdb"] != nil
        else { return "disabled" }
        let sources = viewModel.sources.map(\.id).sorted().joined(separator: ",")
        return "\(item.sourceAccountID ?? "_")|\(item.id)|\(item.providerIDs["Tmdb"] ?? "")|\(sources)|\(seasonRequestRetryToken)"
    }

    private func refreshSeasonRequestAvailability() async {
        guard seasonRequestRefreshKey != "disabled",
              let item = viewModel.state.value?.item,
              let requestAvailabilityRefresh
        else {
            seasonRequestAvailability = nil
            seasonRequestAvailabilityResolved = true
            seasonRequestAvailabilityFailed = false
            return
        }
        seasonRequestAvailability = nil
        seasonRequestAvailabilityResolved = false
        seasonRequestAvailabilityFailed = false
        guard let availability = await requestAvailabilityRefresh(item) else {
            guard !Task.isCancelled else { return }
            seasonRequestAvailabilityResolved = true
            seasonRequestAvailabilityFailed = true
            return
        }
        let ownedSeasonNumbers = isDiscoveryItem
            ? Set<Int>()
            : await viewModel.ownedSeasonNumbersAcrossSources()
        guard !Task.isCancelled else { return }
        seasonRequestAvailability = availability.markingAvailable(Array(ownedSeasonNumbers))
        seasonRequestAvailabilityResolved = true
        seasonRequestAvailabilityFailed = false
    }

    /// Whether the episode is this page's *subject* rather than a season/series
    /// page's fronted child.
    ///
    /// `detail.item.kind` alone is not enough: an `EpisodeContextRoute` seeds the
    /// tapped episode as `initialItem` for an instant first paint and only then
    /// loads the series over it, so during that window the page is showing an
    /// episode while genuinely being the *series* page. `initialEpisode` is set
    /// on exactly that route and nowhere else, so it separates the two.
    private var presentsEpisodeAsSubject: Bool {
        initialEpisode == nil && viewModel.state.value?.item.kind == .episode
    }

    /// Whether another detail page is pushed on top of this one.
    private var hasChildOnTop: Bool {
        guard let ownStackDepth, let depth = stackDepth?.depth else { return false }
        return depth > ownStackDepth
    }

    /// How many detail pages are stacked on top of this one.
    private var coveredBy: Int {
        guard let ownStackDepth, let depth = stackDepth?.depth else { return 0 }
        return max(0, depth - ownStackDepth)
    }

    /// Pages buried at least this deep stop building their content.
    ///
    /// A `NavigationStack` never disappears the page a push covers, so without
    /// this every page ever visited stays fully built — holding its artwork and
    /// re-participating in every SwiftUI invalidation pass. Measured on device:
    /// ~22MB and a growing main-thread stall per level, reaching a 1076ms hitch
    /// by the tenth push. Both symptoms are the same cause counted twice.
    ///
    /// Two, not one: the page directly under the top one is where a Back lands,
    /// so keeping it built makes the common Back instant. Anything deeper needs
    /// at least two presses to reach and can afford to rebuild — and its view
    /// model is usually still in `detailViewModels` (an LRU of 4), so rebuilding
    /// is a re-render rather than a re-fetch.
    private static let shedWhenCoveredBy = 2

    /// Whether this page should stand down and render nothing.
    private var isShed: Bool { coveredBy >= Self.shedWhenCoveredBy }

    private func container(_ detail: ItemDetailViewModel.Detail) -> some View {
        let sources = viewModel.sources
        let serverChoices = serverChoices(from: sources)
        let effectiveSource = effectiveSource(for: detail.item, sources: sources, serverChoices: serverChoices)
        let effectiveVersions = effectiveVersions(for: detail.item, sources: sources, activeAccountID: effectiveSource?.accountID)
        let effectiveVersionID = effectiveVersionID(for: detail.item, in: effectiveVersions)
        // A not-in-library Plex Discover title (a Watchlist movie the user doesn't
        // own on any server) resolves to a global Discover stub with nothing to
        // play — so it must NOT offer a dead Play button. The body (overview/cast/
        // ratings) still renders; the Watchlist toggle keeps the row focusable.
        // Cross-server discovery restores Play the instant it folds in a real copy.
        let canPlay = isPlayable(detail.item)
            && detail.item.hasPlayableLibraryTarget(additionalSources: sources)
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    DetailHeroView(
                        item: detail.item,
                        heroHeightFraction: detail.children.isEmpty ? 1.0 : 0.8,
                        // An episode's own page can be reached from Continue
                        // Watching or Search, where Back leaves the show
                        // entirely — so offer a way over to it.
                        offersParentNavigation: presentsEpisodeAsSubject,
                        presentsEpisodeStill: presentsEpisodeAsSubject,
                        spoilerSettings: spoilerSettings,
                        playTitle: canPlay ? viewModel.playButtonTitle(for: detail.item) : nil,
                        onPlay: canPlay ? {
                            // CRITICAL: re-resolve sources/versions from the
                            // view model at FIRE time, not from the body-eval
                            // capture. Without this, a tap that races a
                            // discovery/snapshot update can fire the old
                            // closure where the picker had already moved on
                            // to a richer version set — picker highlights
                            // 4K, play target still points at the originally-
                            // opened 720p item. Reading viewModel.sources
                            // here guarantees the play target derives from
                            // the SAME source of truth the UI most recently
                            // showed.
                            let liveSources = viewModel.sources
                            let liveServerChoices = self.serverChoices(from: liveSources)
                            let liveSource = self.effectiveSource(for: detail.item, sources: liveSources, serverChoices: liveServerChoices)
                            let liveVersions = self.effectiveVersions(for: detail.item, sources: liveSources, activeAccountID: liveSource?.accountID)
                            let liveVersionID = self.effectiveVersionID(for: detail.item, in: liveVersions)
                            onPlay(self.playItem(for: detail.item, sources: liveSources, activeAccountID: liveSource?.accountID, versionID: liveVersionID))
                        } : nil,
                        playProgress: canPlay ? detail.item.resumeProgressFraction : nil,
                        playRemainingText: canPlay ? detail.item.resumeRemainingText : nil,
                        playSeasonEpisodeText: canPlay ? HeroForegroundModelBuilder.seasonEpisodeButtonText(for: detail.item) : nil,
                        onPlayTrailer: viewModel.trailers.first.map { trailer in { onPlay(trailer) } },
                        versions: effectiveVersions,
                        selectedVersionID: effectiveVersionID,
                        onSelectVersion: { id in selectVersion(id, for: detail.item) },
                        sources: serverChoices,
                        offlineSourceAccountIDs: viewModel.unreachableSourceAccountIDs,
                        selectedSourceAccountID: effectiveSource?.accountID,
                        onSelectSource: serverChoices.count > 1 ? { id in selectSource(id) } : nil,
                        fallbackTechnicalBadges: detail.children.representativeTechnicalBadges,
                        playButtonFocus: $playFocused,
                        // Whenever focus lands on (or moves between) any hero action
                        // button, re-pin the page to the hero top. The row is
                        // bottom-anchored in a full-height hero (childless movie),
                        // so tvOS auto-scrolls the page down to reveal a focused
                        // button; this snaps it back — for every button, not just
                        // Play — killing the horizontal-navigation drift. Same
                        // animation as the Play-regains-focus case below.
                        onHeroActionFocused: {
                            withAnimation(.easeInOut(duration: 0.4)) {
                                proxy.scrollTo(Self.topAnchorID, anchor: .top)
                            }
                        }
                    )
                    .id(Self.topAnchorID)
                    if !detail.children.isEmpty {
                        MediaRowView(
                            title: Text(childrenTitle(for: detail.item)),
                            items: detail.children,
                            style: .landscape,
                            spoilerSettings: spoilerSettings,
                            leadingInset: PlozzTheme.Metrics.heroLeadingPadding,
                            onSelect: onSelectChild
                        )
                    }
                    DetailExtrasView(
                        item: detail.item,
                        selectedSource: effectiveSource
                            ?? (isDiscoveryItem ? nil : viewModel.currentSourceForDisplay),
                        selectedVersion: isDiscoveryItem
                            ? nil
                            : effectiveVersions.first { $0.id == effectiveVersionID }
                                ?? MediaVersion.synthesized(from: detail.item),
                        leadingInset: PlozzTheme.Metrics.heroLeadingPadding,
                        relatedEntries: viewModel.relatedTitlesLoader?.entries ?? [],
                        relatedHasResolved: viewModel.relatedTitlesLoader?.hasResolved ?? true,
                        onSelectRelated: onSelectChild
                    )
                }
                .padding(.bottom, PlozzTheme.Metrics.screenVerticalPadding)
                // Cap the whole scroll column to the proposed (safe viewport)
                // width so an over-wide row can't inflate the column past the
                // viewport and pan the page sideways. The hero backdrop still
                // paints edge-to-edge using its explicit screen-width frame.
                .modifier(DetailForegroundWidth())
            }
            // `.userInitiated` rather than the default `.automatic`: automatic is
            // only a hint, and tvOS otherwise takes the topmost focusable element
            // — which on an episode page is the show breadcrumb above the title,
            // so the page opened focused on "leave" instead of "play".
            .defaultFocus($playFocused, true, priority: .userInitiated)
            // Pin to the top on first load: the Play button is bottom-anchored in
            // the full-screen hero, so initial focus on it makes tvOS auto-scroll
            // the page down. Snap back to the hero top so focus stays on Play.
            .task {
                try? await Task.sleep(nanoseconds: 50_000_000)
                proxy.scrollTo(Self.topAnchorID, anchor: .top)
                // An episode page puts a focusable breadcrumb above the title,
                // and tvOS takes that topmost element on entry no matter what
                // `defaultFocus` declares (tried at both `.automatic` and
                // `.userInitiated`). Naming the target outright is what actually
                // holds. Scoped to episodes so no other detail page changes.
                if detail.item.kind == .episode, canPlay {
                    playFocused = true
                }
            }
            // Snap back to the hero top whenever Play regains focus (e.g. moving
            // "up" from a children rail), animated so the page glides up smoothly.
            // Without this the movie hero stays scrolled down after tvOS frames
            // the bottom-anchored Play button on first focus.
            .onChange(of: playFocused) { _, focused in
                if focused {
                    withAnimation(.easeInOut(duration: 0.4)) {
                        proxy.scrollTo(Self.topAnchorID, anchor: .top)
                    }
                }
            }
            // Never clip a focused card's lift, shadow or border.
            .scrollClipDisabled()
            .modifier(DetailTopSafeAreaBreakout())
        }
    }

    private func isPlayable(_ item: MediaItem) -> Bool {
        // An unaired episode has no file on any server yet.
        guard !item.isUpcomingUnaired else { return false }
        switch item.kind {
        case .movie, .episode, .video: return true
        default: return false
        }
    }

    /// A folder/collection that finished loading with no playable contents. Only
    /// these get the empty state — a series/season with no episodes keeps its
    /// normal hero (its emptiness is a metadata gap, not a browse dead-end).
    private func isEmptyContainer(_ detail: ItemDetailViewModel.Detail) -> Bool {
        switch detail.item.kind {
        case .folder, .collection:
            return detail.childrenLoaded && detail.children.isEmpty
        default:
            return false
        }
    }

    /// A folder/collection whose children are still being fetched (empty list,
    /// not yet loaded). `container` renders nothing focusable for such an item —
    /// no Play button, no children rail, no version/source picker — so on tvOS the
    /// Menu button would exit the app instead of popping the page. We surface a
    /// focusable loading placeholder (with a working Back) for the whole fetch,
    /// which for a slow SMB share can be tens of seconds.
    private func isLoadingContainer(_ detail: ItemDetailViewModel.Detail) -> Bool {
        switch detail.item.kind {
        case .folder, .collection:
            return !detail.childrenLoaded && detail.children.isEmpty
        default:
            return false
        }
    }

    /// Shown when the user drills into a folder that holds no sub-folders and no
    /// playable video (e.g. a folder of `.zip`s). Without this the page would be a
    /// blank hero with NOTHING focusable — and on tvOS a screen with no focusable
    /// element makes the Menu button exit the app instead of popping the page,
    /// trapping the user. The focusable "Go Back" button both explains the empty
    /// folder and restores a working Back.
    private func emptyFolderState(_ item: MediaItem) -> some View {
        VStack(spacing: 24) {
            Image(systemName: "folder")
                .font(.system(size: 64))
                .plozzForeground(.secondary)
            Text(item.title)
                .font(.title2.weight(.semibold))
            Text("No playable media in this folder.")
                .font(.title3)
                .plozzForeground(.secondary)
                .multilineTextAlignment(.center)
            Button {
                dismiss()
            } label: {
                Label("Go Back", systemImage: "chevron.backward")
                    .frame(minWidth: 260)
            }
            .buttonStyle(.borderedProminent)
            .focused($emptyBackFocused)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(PlozzTheme.Metrics.screenVerticalPadding)
        .defaultFocus($emptyBackFocused, true)
    }

    /// Shown while a folder's contents are still being listed (a slow SMB share
    /// can take tens of seconds). Mirrors `emptyFolderState` but with a spinner
    /// and no "empty" copy — its whole job is to keep a focusable element (the
    /// Back button) on screen so tvOS never treats the page as focusless and lets
    /// Menu quit the app mid-load.
    private func loadingFolderState(_ item: MediaItem) -> some View {
        VStack(spacing: 24) {
            ProgressView()
                .scaleEffect(1.5)
            Text(item.title)
                .font(.title2.weight(.semibold))
            Text("Loading…")
                .font(.title3)
                .plozzForeground(.secondary)
            Button {
                dismiss()
            } label: {
                Label("Go Back", systemImage: "chevron.backward")
                    .frame(minWidth: 260)
            }
            .buttonStyle(.borderedProminent)
            .focused($emptyBackFocused)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(PlozzTheme.Metrics.screenVerticalPadding)
        .defaultFocus($emptyBackFocused, true)
    }

    private func childrenTitle(for item: MediaItem) -> LocalizedStringResource {
        "Contents"
    }

    /// The version id `Play` should target right now: the user's in-session
    /// override, else their remembered per-title preference (if still offered),
    /// else the smart capability-aware recommended default. `nil` when the chosen
    /// source has no selectable versions (server picks). Computed against the
    /// *effective source's* versions so switching servers re-defaults correctly.
    private func effectiveVersionID(for item: MediaItem, in versions: [MediaVersion]) -> String? {
        DetailPlaybackSelection.preferredVersionID(
            for: item,
            versions: versions,
            versionOverride: versionOverride,
            preferences: versionPreferences,
            capabilities: capabilities
        )
    }

    /// The server `Play` should target right now: the user's in-session server
    /// override, else the default source — which honors the **origin** when the
    /// detail was opened from a library tile (that library's server), otherwise
    /// the cross-server best-source default (locality, known native compatibility,
    /// then quality) — else the primary. `nil` for a single-server title
    /// (no server picker; legacy version-only flow).
    ///
    /// Same-account duplicates (two Jellyfin items for the same film on one
    /// server) collapse into one server-picker entry: this returns whichever
    /// source ref backs the **active account**, and the version picker takes
    /// over disambiguating the two files.
    private func effectiveSource(
        for item: MediaItem,
        sources: [MediaSourceRef],
        serverChoices: [MediaSourceRef]
    ) -> MediaSourceRef? {
        DetailPlaybackSelection.preferredSource(
            sourceOverride: sourceOverride,
            libraryOrigin: viewModel.originSourceAccountID,
            itemSourceAccountID: item.sourceAccountID,
            sources: sources,
            capabilities: capabilities
        )
    }

    /// The list of server-picker entries: ``viewModel/sources`` deduped by
    /// account id so two same-account duplicate items don't render as two
    /// identical "Server" rows. Same-account siblings are surfaced in the
    /// VERSION picker instead.
    private func serverChoices(from sources: [MediaSourceRef]) -> [MediaSourceRef] {
        DetailPlaybackSelection.serverChoices(from: sources)
    }

    /// The versions to offer in the version picker: every source that belongs to
    /// the active account contributes its files, concatenated in source order.
    /// For the common single-server / single-file case this is just the loaded
    /// item's own versions; for same-account duplicates (one Jellyfin movie
    /// existing as two items on one server) this is the combined list, each
    /// entry carrying its backing item id so playback repoints correctly.
    private func effectiveVersions(
        for item: MediaItem,
        sources: [MediaSourceRef],
        activeAccountID: String?
    ) -> [MediaVersion] {
        DetailPlaybackSelection.versions(
            for: item,
            sources: sources,
            activeAccountID: activeAccountID
        )
    }

    /// Builds the retargeted item `Play` should launch — see
    /// `MediaItem.retargetedForPlayback` for the actual routing rules. Kept as
    /// a thin wrapper so callers in this view can use familiar argument names.
    ///
    /// `explicit` marks the retarget as a deliberate user choice (server or
    /// version picker) so the best-source router honors it as-is; an auto default
    /// (the user opened the page and pressed Play without touching a picker) is
    /// left non-explicit so the router may re-select a more-local copy using live
    /// locality.
    private func playItem(
        for item: MediaItem,
        sources: [MediaSourceRef],
        activeAccountID: String?,
        versionID: String?
    ) -> MediaItem {
        DetailPlaybackSelection.playItem(
            for: item,
            sources: sources,
            activeAccountID: activeAccountID,
            versionID: versionID,
            explicit: viewModel.isLibraryOriginPinned
                || sourceOverride != nil
                || versionOverride != nil
        )
    }

    /// Records the user's server choice for this visit and clears the version
    /// override so the newly-selected server re-defaults to its own best version.
    private func selectSource(_ accountID: String) {
        sourceOverride = accountID
        versionOverride = nil
        Task {
            await viewModel.switchToSource(accountID: accountID)
        }
    }

    /// Records the user's version choice for this visit and remembers it for next
    /// time, keyed per title (per series for an episode).
    private func selectVersion(_ id: String, for item: MediaItem) {
        versionOverride = id
        let key = versionPreferenceKey(for: item)
        guard let version = effectiveVersions(
            for: item,
            sources: viewModel.sources,
            activeAccountID: effectiveSource(
                for: item,
                sources: viewModel.sources,
                serverChoices: serverChoices(from: viewModel.sources)
            )?.accountID
        ).first(where: { $0.id == id }) else {
            versionPreferences.setPreferredVersionID(id, forTitle: key)
            versionPreferences.setPreferredVersionDescriptor(nil, forTitle: key)
            return
        }
        // Remember the exact file AND its shape: the id is what a movie returns
        // to, the shape is what an episode can carry forward.
        versionPreferences.rememberVersion(version, forTitle: key)
    }

    /// Stable key for the per-title version preference. Episodes share their
    /// series' key so a whole show remembers one preferred version.
    private func versionPreferenceKey(for item: MediaItem) -> String {
        DetailPlaybackSelection.versionPreferenceKey(for: item)
    }
}

private struct DetailTopSafeAreaBreakout: ViewModifier {
    func body(content: Content) -> some View {
        #if os(tvOS)
        // `ignoresSafeArea(.top)` also consumes tvOS's transient horizontal safe
        // region during a cold NavigationStack push, briefly proposing a
        // 2,408-point ScrollView. Pull only the known 60-point top inset outward.
        content.padding(.top, -60)
        #else
        content.ignoresSafeArea(.container, edges: .top)
        #endif
    }
}

private struct DetailForegroundWidth: ViewModifier {
    func body(content: Content) -> some View {
        #if os(tvOS)
        // Constrain the ScrollView's actual content, not an outer wrapper. A
        // vertical ScrollView may keep a transient 2,408-point coordinate space
        // during a cold NavigationStack push even inside a 1,760-point frame; its
        // exact-width child remains centered at x=80 and cannot lay out off-screen.
        content.frame(width: UIScreen.main.bounds.width - 160, alignment: .leading)
        #else
        content.frame(maxWidth: .infinity, alignment: .leading)
        #endif
    }
}
#endif
