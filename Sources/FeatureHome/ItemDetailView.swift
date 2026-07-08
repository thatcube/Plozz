#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// Item detail screen: backdrop hero, metadata, Play/Resume, and children.
public struct ItemDetailView: View {
    @State private var viewModel: ItemDetailViewModel
    private let spoilerSettings: SpoilerSettings
    private let onPlay: (MediaItem) -> Void
    private let onSelectChild: (MediaItem) -> Void
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

    /// This device's capabilities, used to drive the smart default version and
    /// the per-version Direct Play / Transcode prediction in the picker.
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
    /// One-time acknowledgement of the "requests as unrestricted admin" explainer.
    /// Device-wide (shared with any other request surface via this key): once the
    /// user has confirmed an admin request once, we don't nag on every subsequent
    /// request — intentionally requesting as admin is a legitimate choice. Mapping
    /// a profile to a Seerr user avoids the admin path (and this prompt) entirely.
    @AppStorage("seerr.adminRequestAcknowledged") private var adminRequestAcknowledged = false

    /// A user-facing request failure, wrapped for `.alert(item:)`.
    private struct RequestFailureAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String?
    }

    public init(
        viewModel: ItemDetailViewModel,
        spoilerSettings: SpoilerSettings = .default,
        onPlay: @escaping (MediaItem) -> Void,
        onSelectChild: @escaping (MediaItem) -> Void,
        initialSeasonID: String? = nil,
        initialEpisode: MediaItem? = nil,
        isDiscoveryItem: Bool = false,
        seerConnected: Bool = false,
        onRequest: ((MediaItem) async -> MediaRequestActionResult)? = nil,
        requestActingName: String? = nil,
        confirmAdminRequest: Bool = false,
        capabilities: MediaCapabilities = .detected(),
        versionPreferences: VersionPreferenceStoring = VersionPreferenceStore()
    ) {
        _viewModel = State(initialValue: viewModel)
        self.spoilerSettings = spoilerSettings
        self.onPlay = onPlay
        self.onSelectChild = onSelectChild
        self.initialSeasonID = initialSeasonID
        self.initialEpisode = initialEpisode
        self.isDiscoveryItem = isDiscoveryItem
        self.seerConnected = seerConnected
        self.onRequest = onRequest
        self.requestActingName = requestActingName
        self.confirmAdminRequest = confirmAdminRequest
        self.capabilities = capabilities
        self.versionPreferences = versionPreferences
    }

    public var body: some View {
        ContentStateView(
            state: viewModel.state,
            onRetry: { Task { await viewModel.load() } }
        ) { detail in
            // A season never has its own page: ItemDetailViewModel transparently
            // redirects a season load to its parent series, so by the time we
            // render here a season has become a `.series`. `container` only ever
            // serves movies, episodes, folders and collections.
            if isDiscoveryItem {
                // A not-in-library discovery title (movie OR series) has no library
                // children/sources to render, and must NOT enter SeriesDetailView
                // (which expects real seasons/episodes). Show a request-focused
                // hero built from the seeded TMDB metadata.
                discoveryDetail(detail)
            } else if detail.item.kind == .series {
                SeriesDetailView(
                    series: detail.item,
                    seasons: detail.children.filter { $0.kind == .season },
                    looseEpisodes: detail.children.filter { $0.kind == .episode },
                    viewModel: viewModel,
                    spoilerSettings: spoilerSettings,
                    onPlay: onPlay,
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
                    initialSeasonID: initialSeasonID ?? viewModel.preselectedSeasonID ?? initialEpisode?.seasonID,
                    initialEpisode: initialEpisode
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
        .onDisappear { viewModel.suspendEnrichment() }
        .onAppear { viewModel.resumeEnrichmentIfNeeded() }
        .onReceive(NotificationCenter.default.publisher(for: .mediaItemDidMutate)) { note in
            if let mutation = MediaItemMutation.from(note) {
                viewModel.applyWatchedState(mutation)
            } else {
                Task { await viewModel.reload() }
            }
        }
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
                onRequest: (onRequest != nil && cta == .request) ? { requestTapped(detail.item) } : nil
            )
            .id(Self.topAnchorID)
        }
        // Never clip the focused request pill's lift/shadow.
        .scrollClipDisabled()
        // Unmapped (admin) requests in a multi-profile household confirm first so a
        // member on an unmapped profile can't silently request as the unrestricted
        // admin. Mapped requests fire directly.
        .confirmationDialog(
            "Request as Admin?",
            isPresented: $showingAdminConfirm,
            titleVisibility: .visible
        ) {
            Button("Request as Admin") {
                adminRequestAcknowledged = true
                performRequest(detail.item)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This profile isn’t linked to a Seerr user, so the request is made as the unrestricted admin. Link a user in Settings to track requests per person.")
        }
        .alert(item: $requestFailure) { failure in
            Alert(
                title: Text(failure.title),
                message: failure.message.map(Text.init),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    /// Handles a Request tap: confirm ONCE for the unmapped admin case in a
    /// household (see `confirmAdminRequest`) so a member on an unmapped profile is
    /// told their request goes as the unrestricted admin — but only until they've
    /// acknowledged it once (intentional admin use shouldn't nag every time).
    /// Mapped requests, and everything after the one-time acknowledgement, fire
    /// directly.
    private func requestTapped(_ item: MediaItem) {
        if confirmAdminRequest && requestActingName == nil && !adminRequestAcknowledged {
            showingAdminConfirm = true
        } else {
            performRequest(item)
        }
    }

    /// Sends a one-tap Seerr request for a discovery title, optimistically flipping
    /// the pill to Requested/Downloading immediately, then reconciling with the
    /// returned result: a success keeps the new status; a failure clears the
    /// optimistic override (so Request returns for a retry) and surfaces an alert.
    private func performRequest(_ item: MediaItem) {
        guard let onRequest else { return }
        requestOverride = .pending
        Task {
            let result = await onRequest(item)
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

    private func container(_ detail: ItemDetailViewModel.Detail) -> some View {
        let sources = viewModel.sources
        let serverChoices = serverChoices(from: sources)
        let effectiveSource = effectiveSource(for: detail.item, sources: sources, serverChoices: serverChoices)
        let effectiveVersions = effectiveVersions(for: detail.item, sources: sources, activeAccountID: effectiveSource?.accountID)
        let effectiveVersionID = effectiveVersionID(for: detail.item, in: effectiveVersions)
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    DetailHeroView(
                        item: detail.item,
                        heroHeightFraction: detail.children.isEmpty ? 1.0 : 0.8,
                        spoilerSettings: spoilerSettings,
                        playTitle: isPlayable(detail.item) ? viewModel.playButtonTitle(for: detail.item) : nil,
                        onPlay: isPlayable(detail.item) ? {
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
                        playProgress: isPlayable(detail.item) ? detail.item.resumeProgressFraction : nil,
                        playRemainingText: isPlayable(detail.item) ? detail.item.resumeRemainingText : nil,
                        onPlayTrailer: viewModel.trailers.first.map { trailer in { onPlay(trailer) } },
                        versions: effectiveVersions,
                        selectedVersionID: effectiveVersionID,
                        capabilities: capabilities,
                        onSelectVersion: { id in selectVersion(id, for: detail.item) },
                        sources: serverChoices,
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
                            title: childrenTitle(for: detail.item),
                            items: detail.children,
                            style: .landscape,
                            spoilerSettings: spoilerSettings,
                            leadingInset: PlozzTheme.Metrics.heroLeadingPadding,
                            onSelect: onSelectChild
                        )
                    }
                    DetailExtrasView(item: detail.item, leadingInset: PlozzTheme.Metrics.heroLeadingPadding)
                }
                .padding(.bottom, PlozzTheme.Metrics.screenPadding)
                // Cap the whole scroll column to the proposed (safe viewport)
                // width so an over-wide row can't inflate the column past the
                // viewport and pan the page sideways. The hero still bleeds
                // edge-to-edge via its own `.ignoresSafeArea`.
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultFocus($playFocused, true)
            // Pin to the top on first load: the Play button is bottom-anchored in
            // the full-screen hero, so initial focus on it makes tvOS auto-scroll
            // the page down. Snap back to the hero top so focus stays on Play.
            .task {
                try? await Task.sleep(nanoseconds: 50_000_000)
                proxy.scrollTo(Self.topAnchorID, anchor: .top)
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
            // Let the hero bleed into the top overscan inset instead of the
            // ScrollView reserving it as a blank bar above the backdrop.
            .ignoresSafeArea(.container, edges: .top)
        }
    }

    private func isPlayable(_ item: MediaItem) -> Bool {
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
                .foregroundStyle(.secondary)
            Text(item.title)
                .font(.title2.weight(.semibold))
            Text("No playable media in this folder.")
                .font(.title3)
                .foregroundStyle(.secondary)
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
        .padding(PlozzTheme.Metrics.screenPadding)
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
                .foregroundStyle(.secondary)
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
        .padding(PlozzTheme.Metrics.screenPadding)
        .defaultFocus($emptyBackFocused, true)
    }

    private func childrenTitle(for item: MediaItem) -> String {
        "Contents"
    }

    /// The version id `Play` should target right now: the user's in-session
    /// override, else their remembered per-title preference (if still offered),
    /// else the smart capability-aware recommended default. `nil` when the chosen
    /// source has no selectable versions (server picks). Computed against the
    /// *effective source's* versions so switching servers re-defaults correctly.
    private func effectiveVersionID(for item: MediaItem, in versions: [MediaVersion]) -> String? {
        guard versions.count > 1 else { return nil }
        if let versionOverride, versions.contains(where: { $0.id == versionOverride }) {
            return versionOverride
        }
        let remembered = versionPreferences.preferredVersionID(forTitle: versionPreferenceKey(for: item))
        if let remembered, versions.contains(where: { $0.id == remembered }) {
            return remembered
        }
        return versions.recommendedSelection(for: capabilities)?.id
    }

    /// The server `Play` should target right now: the user's in-session server
    /// override, else the default source — which honors the **origin** when the
    /// detail was opened from a library tile (that library's server), otherwise
    /// the cross-server best-source default (highest-quality Direct-Play option
    /// this device can play) — else the primary. `nil` for a single-server title
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
        guard serverChoices.count > 1 || sources.count > 1 else { return nil }
        if let sourceOverride, let match = serverChoices.first(where: { $0.accountID == sourceOverride }) {
            return match
        }
        if let selection = CrossSourceSelector.bestSelection(
            from: serverChoices,
            capabilities: capabilities,
            preferring: viewModel.originSourceAccountID
        ) {
            return selection.source
        }
        return serverChoices.first ?? sources.first
    }

    /// The list of server-picker entries: ``viewModel/sources`` deduped by
    /// account id so two same-account duplicate items don't render as two
    /// identical "Server" rows. Same-account siblings are surfaced in the
    /// VERSION picker instead.
    private func serverChoices(from sources: [MediaSourceRef]) -> [MediaSourceRef] {
        var seen = Set<String>()
        var result: [MediaSourceRef] = []
        for source in sources where seen.insert(source.accountID).inserted {
            result.append(source)
        }
        return result
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
        guard let activeAccountID else { return item.versions.sortedForPicker() }
        let active = sources.filter { $0.accountID == activeAccountID }
        guard !active.isEmpty else { return item.versions.sortedForPicker() }
        return active.flatMap(\.versions).sortedForPicker()
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
        MediaItem.retargetedForPlayback(
            item: item,
            sources: sources,
            activeAccountID: activeAccountID,
            versionID: versionID,
            explicit: sourceOverride != nil || versionOverride != nil
        )
    }

    /// Records the user's server choice for this visit and clears the version
    /// override so the newly-selected server re-defaults to its own best version.
    private func selectSource(_ accountID: String) {
        sourceOverride = accountID
        versionOverride = nil
    }

    /// Records the user's version choice for this visit and remembers it for next
    /// time, keyed per title (per series for an episode).
    private func selectVersion(_ id: String, for item: MediaItem) {
        versionOverride = id
        versionPreferences.setPreferredVersionID(id, forTitle: versionPreferenceKey(for: item))
    }

    /// Stable key for the per-title version preference. Episodes share their
    /// series' key so a whole show remembers one preferred version.
    private func versionPreferenceKey(for item: MediaItem) -> String {
        item.seriesID ?? item.id
    }
}

#endif
