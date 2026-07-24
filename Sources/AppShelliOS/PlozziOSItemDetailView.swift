#if os(iOS)
import AppRuntime
import CoreModels
import CoreUI
import FeatureHomeCore
import MediaDownloads
import SeerService
import SwiftUI

struct PlozziOSItemDetailView: View {
    let appModel: PlozziOSAppModel
    let provider: any MediaProvider
    let item: MediaItem
    let seerService: SeerService?
    let originSourceAccountID: String?

    @State private var resolvedSeries: MediaItem?
    @State private var resolvedContextItem: MediaItem?
    @State private var resolutionError: String?
    @State private var retryToken = 0

    init(
        appModel: PlozziOSAppModel,
        provider: any MediaProvider,
        item: MediaItem,
        seerService: SeerService? = nil,
        originSourceAccountID: String? = nil
    ) {
        self.appModel = appModel
        self.provider = provider
        self.item = item
        self.seerService = seerService
        self.originSourceAccountID = originSourceAccountID
    }

    var body: some View {
        if shouldResolveSeries {
            if let resolvedSeries {
                canonicalDetail(for: resolvedSeries)
            } else if let resolutionError {
                ContentUnavailableView {
                    Label(
                        "Unable to load show",
                        systemImage: "exclamationmark.triangle"
                    )
                } description: {
                    Text(resolutionError)
                } actions: {
                    Button("Try Again") {
                        self.resolutionError = nil
                        retryToken &+= 1
                    }
                }
                .task(id: retryToken) { await resolveSeries() }
            } else {
                ProgressView("Loading show…")
                    .task(id: retryToken) { await resolveSeries() }
            }
        } else {
            canonicalDetail(for: item)
        }
    }

    private var shouldResolveSeries: Bool {
        !item.isNotInLibraryDiscovery
            && (item.kind == .episode || item.kind == .season)
            && item.seriesID != nil
    }

    private func canonicalDetail(for resolvedItem: MediaItem) -> some View {
        let contextItem = resolvedContextItem ?? item
        return PlozziOSCanonicalItemDetailView(
            appModel: appModel,
            provider: provider,
            item: resolvedItem,
            seerService: seerService,
            originSourceAccountID: originSourceAccountID,
            initialSeasonID: contextItem.kind == .season
                ? contextItem.id
                : contextItem.seasonID,
            initialEpisode: contextItem.kind == .episode
                ? contextItem
                : nil
        )
    }

    private func resolveSeries() async {
        do {
            var contextItem = (try? await provider.item(id: item.id)) ?? item
            if contextItem.sourceAccountID == nil,
               let sourceAccountID = item.sourceAccountID {
                contextItem = contextItem.taggingSource(sourceAccountID)
            }
            guard let seriesID = contextItem.seriesID else {
                throw AppError.notFound
            }
            var series = try await provider.item(id: seriesID)
            guard !Task.isCancelled else { return }
            if series.sourceAccountID == nil,
               let sourceAccountID = item.sourceAccountID {
                series = series.taggingSource(sourceAccountID)
            }
            resolvedContextItem = contextItem
            resolvedSeries = series
            resolutionError = nil
        } catch {
            guard !Task.isCancelled else { return }
            resolutionError = (error as? AppError)?.userMessage
                ?? error.localizedDescription
        }
    }
}

private struct PlozziOSCanonicalItemDetailView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.themePalette) private var palette
    @Environment(HeroTrailerController.self) private var trailerController
    @Environment(PlozziOSAppModel.self) private var appModel
    @State private var viewModel: ItemDetailViewModel
    @State private var playbackRequest: PlozziOSPlaybackRequest?
    @State private var downloadRecord: DownloadedMediaRecord?
    @State private var downloadError: String?
    @State private var requestError: String?
    @State private var isRequesting = false
    @State private var requestConfirmationItem: MediaItem?
    @State private var requestConfirmationSeasons: [Int]?
    @State private var seasonRequestAvailability: MediaRequestAvailability?
    @State private var requestStatusOverride: MediaAvailabilityStatus?
    @State private var sourceOverride: String?
    @State private var versionOverride: String?
    @State private var seriesPlayTarget: MediaItem?
    @State private var heroPullDistance: CGFloat = 0
    private let seerService: SeerService?
    private let isDiscoveryItem: Bool
    private let initialSources: [MediaSourceRef]
    private let initialSeasonID: String?
    private let initialEpisode: MediaItem?
    private let capabilities = MediaCapabilities.detected()

    init(
        appModel: PlozziOSAppModel,
        provider: any MediaProvider,
        item: MediaItem,
        seerService: SeerService? = nil,
        originSourceAccountID: String? = nil,
        initialSeasonID: String? = nil,
        initialEpisode: MediaItem? = nil
    ) {
        self.seerService = seerService
        self.initialSeasonID = initialSeasonID
        self.initialEpisode = initialEpisode
        _seriesPlayTarget = State(initialValue: initialEpisode)
        let isDiscoveryItem = item.isNotInLibraryDiscovery
        self.isDiscoveryItem = isDiscoveryItem
        let discoveryStatusRefresh:
            (@Sendable (MediaItem) async -> (MediaAvailabilityStatus, Double?)?)?
        if isDiscoveryItem {
            discoveryStatusRefresh = { [seerService] item in
                await seerService?.availability(for: item)
            }
        } else {
            discoveryStatusRefresh = nil
        }
        let indexedSources = isDiscoveryItem
            ? []
            : appModel.identityIndex.identitySourcesProvider(item)
        var seenSources = Set<String>()
        let initialSources = (item.sources + indexedSources).filter {
            seenSources.insert($0.id).inserted
        }
        self.initialSources = initialSources
        let accounts = appModel.accountsProviders.homeAccounts
        let identitySources = appModel.identityIndex.identitySourcesProvider
        _viewModel = State(
            initialValue: ItemDetailViewModel(
                provider: provider,
                itemID: item.id,
                initialItem: item,
                isDiscoveryItem: isDiscoveryItem,
                discoveryStatusRefresh: discoveryStatusRefresh,
                sourceAccountID: item.sourceAccountID,
                originSourceAccountID: originSourceAccountID,
                initialSources: initialSources,
                alternateProviderResolver: { accountID in
                    appModel.accountsProviders.provider(forAccountID: accountID)
                },
                crossServerSourceResolver: isDiscoveryItem
                    ? nil
                    : crossServerSourceResolver(
                        in: accounts,
                        identitySources: identitySources
                    )
            )
        )
    }

    var body: some View {
        Group {
            switch viewModel.state {
            case .idle, .loading:
                ProgressView("Loading details…")
            case .empty:
                ContentUnavailableView(
                    "Details unavailable",
                    systemImage: "film.stack"
                )
            case let .loaded(detail):
                detailContent(detail)
            case let .failed(error):
                ContentUnavailableView {
                    Label("Unable to load details", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error.userMessage)
                } actions: {
                    Button("Try Again") {
                        Task { await viewModel.reload() }
                    }
                }

            }
        }
        .background(palette.backgroundBase.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if trailerController.isPlaying,
               trailerController.activeSurfaceRole == .detail,
               trailerController.currentItemID == viewModel.state.value?.item.id {
                ToolbarItem(placement: .topBarTrailing) {
                    PlozziOSTrailerMuteToolbarButton(
                        isMuted: trailerController.isMuted,
                        onToggle: trailerController.toggleMuted
                    )
                }
            }
        }
        .task { await viewModel.load() }
        .alert(
            "Seerr",
            isPresented: Binding(
                get: { requestError != nil },
                set: { if !$0 { requestError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(requestError ?? "")
        }
        .fullScreenCover(item: $playbackRequest) {
            if let playbackProvider = appModel.provider(for: $0.item) {
                PlozziOSPlayerView(request: $0, provider: playbackProvider)
            } else {
                ContentUnavailableView(
                    "Server unavailable",
                    systemImage: "server.rack",
                    description: Text("Reconnect the selected server and try again.")
                )
            }
        }
        .confirmationDialog(
            "Request as Administrator?",
            isPresented: Binding(
                get: { requestConfirmationItem != nil },
                set: {
                    if !$0 {
                        requestConfirmationItem = nil
                        requestConfirmationSeasons = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Request as Administrator") {
                guard let item = requestConfirmationItem else { return }
                let seasons = requestConfirmationSeasons
                requestConfirmationItem = nil
                requestConfirmationSeasons = nil
                Task { await request(item, seasons: seasons) }
            }
            Button("Cancel", role: .cancel) {
                requestConfirmationItem = nil
                requestConfirmationSeasons = nil
            }
        } message: {
            Text(
                "This profile isn’t linked to a Seerr user. "
                    + "The request will use the unrestricted administrator account."
            )
        }
    }

    private func detailContent(_ detail: ItemDetailViewModel.Detail) -> some View {
        let heroTarget = seriesPlayTarget ?? detail.item
        let playableHeroTarget = seriesPlayTarget.map(playbackItem(for:))
            ?? detailPlayableItem(for: detail.item)
        let options = detailPlaybackOptions(for: heroTarget)
        let heroStyle: HeroArtworkStyle = horizontalSizeClass == .compact
            ? .compactPortrait
            : .landscape
        let trailerPauseThreshold = PlozziOSHeroMetrics.height(
            style: heroStyle,
            surfaceRole: .detail,
            dynamicTypeSize: dynamicTypeSize
        ) / 2
        return ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PlozziOSDetailHeroSection(
                    item: heroTarget,
                    backdropItem: detail.item,
                    playableItem: playableHeroTarget,
                    downloadItem: playableHeroTarget,
                    sources: options.sources,
                    selectedSourceAccountID: options.selectedSourceAccountID,
                    versions: options.versions,
                    selectedVersionID: options.selectedVersionID,
                    onSelectSource: selectSource,
                    onSelectVersion: {
                        selectVersion($0, for: heroTarget)
                    },
                    actionHandler: appModel.mediaItemActionHandler,
                    onPlay: play,
                    heroRequest: heroRequest(for: detail.item),
                    pullDistance: heroPullDistance
                )

                if detail.item.kind == .series {
                    PlozziOSInlineSeriesBrowser(
                        viewModel: viewModel,
                        seasons: detail.children.filter { $0.kind == .season },
                        looseEpisodes: detail.children.filter { $0.kind == .episode },
                        initialSeasonID: initialSeasonID,
                        initialEpisode: initialEpisode,
                        onPlayTargetChange: { seriesPlayTarget = $0 },
                        onPlay: play,
                        onDownloadSeason: downloadSeason,
                        seasonRequestAvailability: isDiscoveryItem
                            ? nil
                            : seasonRequestAvailability,
                        isRequestingSeasons: isRequesting,
                        seasonRequestError: requestError,
                        onRequestSeasons: {
                            beginRequest(detail.item, seasons: $0)
                        }
                    )
                }

                if isDiscoveryItem, detail.item.kind != .movie, detail.item.kind != .series {
                    PlozziOSRequestAction(
                        item: detail.item,
                        availability: requestStatusOverride ?? detail.item.availability ?? .unknown,
                        isRequesting: isRequesting,
                        errorMessage: requestError,
                        actingName: appModel.activeSeerrUserName,
                        onRequest: { beginRequest($0) }
                    )
                    .padding(.horizontal, pageInset)
                }

                if !detail.item.people.filter(\.isCast).isEmpty {
                    PlozziOSCastSection(people: detail.item.people.filter(\.isCast))
                }

                DetailInformationSections(
                    item: detail.item,
                    horizontalInset: pageInset,
                    selectedSource: options.sources.first {
                        $0.accountID == options.selectedSourceAccountID
                    } ?? (isDiscoveryItem ? nil : viewModel.currentSourceForDisplay),
                    selectedVersion: isDiscoveryItem
                        ? nil
                        : options.versions.first {
                            $0.id == options.selectedVersionID
                        } ?? MediaVersion.synthesized(from: heroTarget)
                )
            }
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        .scrollClipDisabled()
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y > trailerPauseThreshold
        } action: { _, isPastHalfHero in
            trailerController.setPaused(isPastHalfHero)
        }
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            let topOffset = geometry.contentOffset.y
                + geometry.contentInsets.top
            return max(0, -topOffset)
        } action: { _, pullDistance in
            heroPullDistance = pullDistance
        }
        .ignoresSafeArea(.container, edges: .top)
        .navigationTitle("")
        .task(id: seasonRequestLookupID(for: detail)) {
            await loadSeasonRequestAvailability(for: detail)
        }
        .task(id: isDiscoveryItem) {
            await pollDiscoveryStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: .mediaItemDidMutate)) { note in
            guard let mutation = MediaItemMutation.from(note) else { return }
            viewModel.applyWatchedState(mutation)
        }
    }

    /// Polls a discovery title's live Seerr status while the detail page is open
    /// so a request made here (or elsewhere) reflects in the hero CTA
    /// (Request → Requested → Downloading % → Play) — mirroring the Home hero.
    /// Fast while a request is still spinning up, relaxed once downloading/idle.
    private func pollDiscoveryStatus() async {
        guard isDiscoveryItem else { return }
        while !Task.isCancelled {
            await viewModel.refreshDiscoveryStatusNow()
            if Task.isCancelled { return }
            let item = viewModel.state.value?.item
            let transitional: Bool
            switch item?.availability {
            case .pending: transitional = true
            case .processing: transitional = item?.downloadProgress == nil
            default: transitional = requestStatusOverride != nil
            }
            try? await Task.sleep(for: transitional ? .seconds(4) : .seconds(20))
        }
    }

    private var pageInset: CGFloat {
        PlozziOSPageLayout.horizontalInset(for: horizontalSizeClass)
    }

    /// The Seerr request CTA shown in the hero for a discovery **movie or series**.
    /// Movies get a one-tap request; series get a season-picker menu (once the
    /// season availability has loaded) so you choose which seasons to request.
    /// `nil` for in-library items and other kinds.
    private func heroRequest(for item: MediaItem) -> PlozziOSHeroRequest? {
        guard isDiscoveryItem, item.kind == .movie || item.kind == .series else { return nil }
        let availability = requestStatusOverride ?? item.availability
        let isSeries = item.kind == .series
        return PlozziOSHeroRequest(
            cta: MediaItem.heroCTA(
                availability: availability,
                downloadProgress: item.downloadProgress,
                seerConnected: appModel.seerService.isConfigured
            ),
            isRequesting: isRequesting,
            actingName: appModel.activeSeerrUserName,
            onRequest: { beginRequest($0) },
            seasonAvailability: isSeries ? seasonRequestAvailability : nil,
            onRequestSeasons: isSeries ? { beginRequest(item, seasons: $0) } : nil
        )
    }

    private struct DetailPlaybackOptions {
        let sources: [MediaSourceRef]
        let selectedSourceAccountID: String?
        let versions: [MediaVersion]
        let selectedVersionID: String?
    }

    private func detailPlaybackOptions(
        for item: MediaItem
    ) -> DetailPlaybackOptions {
        let available = availableSources
        let source = DetailPlaybackSelection.preferredSource(
            sourceOverride: sourceOverride,
            libraryOrigin: viewModel.originSourceAccountID,
            itemSourceAccountID: item.sourceAccountID,
            sources: available,
            capabilities: capabilities
        )
        let sources = DetailPlaybackSelection.serverChoices(from: available)
        let versions = DetailPlaybackSelection.versions(
            for: item,
            sources: available,
            activeAccountID: source?.accountID
        )
        let selectedVersionID = DetailPlaybackSelection.preferredVersionID(
            for: item,
            versions: versions,
            versionOverride: versionOverride,
            preferences: appModel.versionPreferences,
            capabilities: capabilities
        )
        return DetailPlaybackOptions(
            sources: sources,
            selectedSourceAccountID: source?.accountID
                ?? item.sourceAccountID,
            versions: versions,
            selectedVersionID: selectedVersionID
        )
    }

    private func detailPlayableItem(for item: MediaItem) -> MediaItem? {
        guard !isDiscoveryItem,
              item.kind == .movie
                || item.kind == .episode
                || item.kind == .video else {
            return nil
        }
        return playbackItem(for: item)
    }

    private func downloadSeason(
        _ season: MediaItem,
        episodes: [MediaItem]
    ) async throws -> Int {
        let playableEpisodes = episodes
        guard let first = playableEpisodes.first,
              let provider = appModel.provider(for: first)
                ?? appModel.provider(for: season) else {
            throw PlozziOSSeasonDownloadError.serverUnavailable
        }
        let records = try await appModel.downloads.enqueueSeason(
            season: season,
            episodes: playableEpisodes,
            provider: provider
        )
        return records.count
    }

    @ViewBuilder
    private func sourceAndVersionControls(for item: MediaItem) -> some View {
        let sources = availableSources
        let source = DetailPlaybackSelection.preferredSource(
            sourceOverride: sourceOverride,
            libraryOrigin: viewModel.originSourceAccountID,
            itemSourceAccountID: item.sourceAccountID,
            sources: sources,
            capabilities: capabilities
        )
        let choices = DetailPlaybackSelection.serverChoices(from: sources)
        let versions = DetailPlaybackSelection.versions(
            for: item,
            sources: sources,
            activeAccountID: source?.accountID
        )
        let versionID = DetailPlaybackSelection.preferredVersionID(
            for: item,
            versions: versions,
            versionOverride: versionOverride,
            preferences: appModel.versionPreferences,
            capabilities: capabilities
        )
        if choices.count > 1 || versions.count > 1 {
            PlozziOSSourceVersionControls(
                sources: choices,
                selectedSourceID: source?.accountID ?? item.sourceAccountID,
                versions: versions,
                selectedVersionID: versionID,
                onSelectSource: selectSource,
                onSelectVersion: { selectVersion($0, for: item) }
            )
        }
    }

    private struct PlozziOSDetailManagementActions: View {
        let item: MediaItem
        let handler: any MediaItemActionHandling

        private var actions: [MediaItemAction] {
            handler.actions(for: item, context: .none)
                .filter { !$0.isNavigation }
        }

        var body: some View {
            if !actions.isEmpty {
                Menu {
                    ForEach(actions) { action in
                        Button(action.title, systemImage: action.systemImage) {
                            handler.perform(action, on: item, context: .none)
                        }
                    }
                } label: {
                    Label("More Actions", systemImage: "ellipsis.circle")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func play(_ item: MediaItem, fromBeginning: Bool = false) {
        trailerController.stop()
        playbackRequest = PlozziOSPlaybackRequest(
            item: item,
            startPosition: fromBeginning ? 0 : (item.resumePosition ?? 0)
        )
    }

    private var availableSources: [MediaSourceRef] {
        viewModel.sources.isEmpty ? initialSources : viewModel.sources
    }

    private func playbackItem(for item: MediaItem) -> MediaItem {
        let sources = availableSources
        let source = DetailPlaybackSelection.preferredSource(
            sourceOverride: sourceOverride,
            libraryOrigin: viewModel.originSourceAccountID,
            itemSourceAccountID: item.sourceAccountID,
            sources: sources,
            capabilities: capabilities
        )
        let versions = DetailPlaybackSelection.versions(
            for: item,
            sources: sources,
            activeAccountID: source?.accountID
        )
        let versionID = DetailPlaybackSelection.preferredVersionID(
            for: item,
            versions: versions,
            versionOverride: versionOverride,
            preferences: appModel.versionPreferences,
            capabilities: capabilities
        )
        let selected = DetailPlaybackSelection.playItem(
            for: item,
            sources: sources,
            activeAccountID: source?.accountID,
            versionID: versionID,
            explicit: viewModel.isLibraryOriginPinned
                || sourceOverride != nil
                || versionOverride != nil
        )
        return PlaybackSourceSelection.bestPlayItem(
            selected,
            accounts: appModel.accountsProviders.resolvedActiveAccounts,
            identitySources: appModel.identityIndex.identitySourcesProvider
        )
    }

    private func downloadLookupID(for item: MediaItem) -> String {
        let playable = playbackItem(for: item)
        return [
            playable.sourceAccountID ?? "_",
            playable.id,
            playable.selectedVersionID ?? "_"
        ].joined(separator: "|")
    }

    private func selectSource(_ accountID: String) {
        sourceOverride = accountID
        versionOverride = nil
        Task { await viewModel.switchToSource(accountID: accountID) }
    }

    private func selectVersion(_ id: String, for item: MediaItem) {
        versionOverride = id
        appModel.versionPreferences.setPreferredVersionID(
            id,
            forTitle: DetailPlaybackSelection.versionPreferenceKey(for: item)
        )
    }

    private func beginRequest(_ item: MediaItem, seasons: [Int]? = nil) {
        if appModel.activeSeerrUserID == nil, appModel.profiles.profiles.count > 1 {
            requestConfirmationItem = item
            requestConfirmationSeasons = seasons
        } else {
            Task { await request(item, seasons: seasons) }
        }
    }

    private func request(_ item: MediaItem, seasons: [Int]? = nil) async {
        guard let seerService else {
            requestError = "Connect Overseerr or Jellyseerr in Settings first."
            return
        }
        isRequesting = true
        requestError = nil
        defer { isRequesting = false }
        let outcome = await seerService.request(
            item,
            seasons: seasons,
            actingUserID: appModel.activeSeerrUserID
        )
        switch outcome {
        case let .success(status):
            if let seasons {
                seasonRequestAvailability = seasonRequestAvailability?
                    .markingRequested(seasons)
            } else {
                requestStatusOverride = status
            }
            await viewModel.load()
        case .failure(.alreadyRequested):
            // Seerr already tracks this title — the seeded availability was
            // stale. Pull the real status so the CTA reflects reality instead of
            // showing a misleading error.
            if let status = await appModel.seerService.availability(for: item) {
                requestStatusOverride = status.0
            }
            await viewModel.load()
        case let .failure(reason):
            requestError = reason.userMessage
        }
    }

    private func loadSeasonRequestAvailability(
        for detail: ItemDetailViewModel.Detail
    ) async {
        guard detail.item.kind == .series,
              let seerService,
              seerService.isConfigured else {
            seasonRequestAvailability = nil
            return
        }
        seasonRequestAvailability = await seerService
            .requestAvailability(for: detail.item)?
            .markingAvailable(
                detail.children.compactMap {
                    $0.kind == .season || $0.kind == .episode
                        ? $0.seasonNumber
                        : nil
                }
            )
    }

    private func seasonRequestLookupID(
        for detail: ItemDetailViewModel.Detail
    ) -> String {
        let seasons = detail.children.compactMap(\.seasonNumber)
            .map(String.init)
            .joined(separator: ",")
        return "\(detail.item.id):\(seasons):\(seerService?.isConfigured == true)"
    }

    private func requestFailureMessage(_ reason: SeerRequestFailure) -> String {
        reason.userMessage
    }

    private var currentDownloadRecord: DownloadedMediaRecord? {
        guard let downloadRecord else { return nil }
        return appModel.downloads.records.first {
            $0.identityKey == downloadRecord.identityKey
        } ?? downloadRecord
    }

    private func download(_ item: MediaItem) async {
        do {
            guard let downloadProvider = appModel.provider(for: item) else {
                downloadError = "The selected server is no longer available."
                return
            }
            downloadRecord = try await appModel.downloads.enqueue(
                item: item,
                provider: downloadProvider
            )
            downloadError = nil
        } catch {
            downloadError = error.localizedDescription
        }
    }

    private func pauseDownload() async {
        guard let downloadRecord else { return }
        await appModel.downloads.pause(downloadRecord)
        self.downloadRecord = appModel.downloads.records.first {
            $0.identityKey == downloadRecord.identityKey
        }
    }

    private func resumeDownload() async {
        guard let downloadRecord else { return }
        await appModel.downloads.resume(downloadRecord)
        self.downloadRecord = appModel.downloads.records.first {
            $0.identityKey == downloadRecord.identityKey
        }
    }

    private func removeDownload(_ item: MediaItem) async {
        guard let downloadRecord else { return }
        await appModel.downloads.remove(downloadRecord)
        self.downloadRecord = await appModel.downloads.record(for: item)
    }
}

private struct PlozziOSSourceVersionControls: View {
    let sources: [MediaSourceRef]
    let selectedSourceID: String?
    let versions: [MediaVersion]
    let selectedVersionID: String?
    let onSelectSource: (String) -> Void
    let onSelectVersion: (String) -> Void
    @State private var isVersionPickerPresented = false

    var body: some View {
        HStack(spacing: 12) {
            if sources.count > 1 {
                Menu {
                    ForEach(sources) { source in
                        Button {
                            onSelectSource(source.accountID)
                        } label: {
                            sourceSelectionLabel(
                                source,
                                selected: source.accountID == selectedSourceID
                            )
                        }
                    }
                } label: {
                    sourceMenuLabel(selectedSource)
                }
                .buttonStyle(.bordered)
            }

            if versions.count > 1, let selectedVersion {
                Button {
                    isVersionPickerPresented = true
                } label: {
                    Label(
                        selectedVersion.displayLabel,
                        systemImage: "film.stack"
                    )
                }
                .buttonStyle(.bordered)
                .popover(
                    isPresented: $isVersionPickerPresented,
                    attachmentAnchor: .rect(.bounds),
                    arrowEdge: .top
                ) {
                    PlozziOSVersionPickerPopover(
                        versions: versions.sortedForPicker(),
                        selectedVersionID: selectedVersion.id,
                        onSelectVersion: onSelectVersion
                    )
                    .presentationCompactAdaptation(.popover)
                }
            }
        }
    }

    private var selectedSource: MediaSourceRef? {
        sources.first { $0.accountID == selectedSourceID }
    }

    private var selectedVersion: MediaVersion? {
        versions.first { $0.id == selectedVersionID } ?? versions.first
    }

    private func sourceMenuLabel(
        _ source: MediaSourceRef?
    ) -> some View {
        HStack(spacing: 8) {
            if let provider = source?.providerKind {
                ProviderBrandMark(
                    provider: provider,
                    size: 20,
                    showsBackground: false
                )
            }
            Text(source?.displayName ?? "Server")
        }
    }

    private func sourceSelectionLabel(
        _ source: MediaSourceRef,
        selected: Bool
    ) -> some View {
        HStack(spacing: 8) {
            if let provider = source.providerKind {
                ProviderBrandMark(
                    provider: provider,
                    size: 18,
                    showsBackground: false
                )
            }
            Text(source.displayName)
            if selected {
                Image(systemName: "checkmark")
            }
        }
    }

}

private struct PlozziOSVersionPickerPopover: View {
    let versions: [MediaVersion]
    let selectedVersionID: String
    let onSelectVersion: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(versions) { version in
                    Button {
                        onSelectVersion(version.id)
                        dismiss()
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Image(systemName: "checkmark")
                                .frame(width: 18)
                                .opacity(version.id == selectedVersionID ? 1 : 0)
                                .accessibilityHidden(version.id != selectedVersionID)
                            Text(version.displayLabel)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(
                        version.id == selectedVersionID ? .isSelected : []
                    )
                }
            }
            .padding(.vertical, 8)
        }
        .frame(minWidth: 320, idealWidth: 380, maxWidth: 440, maxHeight: 440)
    }
}

private struct PlozziOSRequestAction: View {
    let item: MediaItem
    let availability: MediaAvailabilityStatus
    let isRequesting: Bool
    let errorMessage: String?
    let actingName: String?
    let onRequest: (MediaItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch availability {
            case .unknown, .deleted:
                Button {
                    onRequest(item)
                } label: {
                    if isRequesting {
                        ProgressView()
                    } else {
                        Label(
                            item.kind == .series ? "Request Series" : "Request Movie",
                            systemImage: "plus.rectangle.on.folder"
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRequesting)
                if let actingName {
                    Text("Request as \(actingName)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            case .pending:
                Label("Requested — awaiting approval", systemImage: "clock")
                    .foregroundStyle(.orange)
            case .processing:
                Label("Downloading", systemImage: "arrow.down.circle")
                    .foregroundStyle(.blue)
            case .partiallyAvailable:
                Label("Partially available", systemImage: "circle.lefthalf.filled")
                    .foregroundStyle(.green)
            case .available:
                Label("Available in your library", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }
}

private struct PlozziOSSeasonRequestMenu: View {
    let availability: MediaRequestAvailability
    let isRequesting: Bool
    let onRequest: ([Int]) -> Void

    private var seasons: [MediaSeasonRequestState] {
        availability.requestPickerSeasons
    }

    private var requestableSeasons: [MediaSeasonRequestState] {
        seasons.filter(\.isRequestable)
    }

    var body: some View {
        Menu {
            if requestableSeasons.count > 1 {
                Button("Request All Missing Seasons") {
                    onRequest(requestableSeasons.map(\.number))
                }
                Divider()
            }

            ForEach(seasons) { season in
                if season.requestFailed {
                    Label(
                        "\(season.title) — Failed",
                        systemImage: "exclamationmark.circle"
                    )
                } else if season.isRequestable {
                    Button("Request \(season.title)") {
                        onRequest([season.number])
                    }
                } else {
                    Label(
                        "\(season.title) — \(statusText(for: season))",
                        systemImage: season.status == .processing
                            ? "arrow.down.circle"
                            : "clock"
                    )
                }
            }
        } label: {
            if isRequesting {
                ProgressView()
                    .frame(width: 44, height: 44)
            } else {
                Image(systemName: "plus.rectangle.on.folder")
                    .font(.headline)
                    .frame(width: 44, height: 44)
            }
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .disabled(isRequesting || seasons.isEmpty)
        .accessibilityLabel("Request missing seasons")
    }

    private func statusText(for season: MediaSeasonRequestState) -> String {
        switch season.status {
        case .processing:
            "Processing"
        case .available, .partiallyAvailable:
            "Available"
        case .pending:
            "Requested"
        case .unknown, .deleted:
            season.requestFailed ? "Failed" : "Unavailable"
        }
    }
}

private struct PlozziOSDownloadAction: View {
    let item: MediaItem
    let record: DownloadedMediaRecord?
    let errorMessage: String?
    let onDownload: () -> Void
    let onPause: () -> Void
    let onResume: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let record {
                    statusControl(record)
                } else {
                    Button(action: onDownload) {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.bordered)
                }
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private func statusControl(_ record: DownloadedMediaRecord) -> some View {
        switch record.status {
        case .queued:
            Label("Queued", systemImage: "clock")
            Button("Cancel", role: .destructive, action: onRemove)
        case .downloading:
            ProgressView(value: record.fractionCompleted ?? 0)
                .frame(maxWidth: 240)
            Button("Pause", action: onPause)
        case .paused:
            Button("Resume Download", action: onResume)
            Button("Remove", role: .destructive, action: onRemove)
        case .failed:
            Button("Try Download Again", action: onResume)
            Button("Remove", role: .destructive, action: onRemove)
        case .completed:
            Label("Available Offline", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Button("Remove Download", role: .destructive, action: onRemove)
        }
    }
}

private struct PlozziOSInlineSeriesBrowser: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selectedSeasonID: String?
    @State private var isDownloadingSeason = false
    @State private var seasonDownloadError: String?
    @State private var seasonDownloadPrompt: PlozziOSSeasonDownloadPrompt?

    let viewModel: ItemDetailViewModel
    let seasons: [MediaItem]
    let looseEpisodes: [MediaItem]
    let initialEpisode: MediaItem?
    let onPlayTargetChange: (MediaItem?) -> Void
    let onPlay: (MediaItem, Bool) -> Void
    let onDownloadSeason: (MediaItem, [MediaItem]) async throws -> Int
    let seasonRequestAvailability: MediaRequestAvailability?
    let isRequestingSeasons: Bool
    let seasonRequestError: String?
    let onRequestSeasons: ([Int]) -> Void

    init(
        viewModel: ItemDetailViewModel,
        seasons: [MediaItem],
        looseEpisodes: [MediaItem],
        initialSeasonID: String?,
        initialEpisode: MediaItem?,
        onPlayTargetChange: @escaping (MediaItem?) -> Void,
        onPlay: @escaping (MediaItem, Bool) -> Void,
        onDownloadSeason:
            @escaping (MediaItem, [MediaItem]) async throws -> Int,
        seasonRequestAvailability: MediaRequestAvailability?,
        isRequestingSeasons: Bool,
        seasonRequestError: String?,
        onRequestSeasons: @escaping ([Int]) -> Void
    ) {
        self.viewModel = viewModel
        self.seasons = seasons
        self.looseEpisodes = looseEpisodes
        self.initialEpisode = initialEpisode
        self.onPlayTargetChange = onPlayTargetChange
        self.onPlay = onPlay
        self.onDownloadSeason = onDownloadSeason
        self.seasonRequestAvailability = seasonRequestAvailability
        self.isRequestingSeasons = isRequestingSeasons
        self.seasonRequestError = seasonRequestError
        self.onRequestSeasons = onRequestSeasons
        _selectedSeasonID = State(
            initialValue: initialEpisode?.seasonID ?? initialSeasonID
        )
    }

    var body: some View {
        if !seasons.isEmpty || !looseEpisodes.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                if !seasons.isEmpty {
                    HStack(spacing: 10) {
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal) {
                            LazyHStack(spacing: 10) {
                                ForEach(seasons) { season in
                                    PlozziOSSeasonButton(
                                        title: season.title,
                                        isSelected:
                                            season.id == selectedSeasonID
                                    ) {
                                        selectedSeasonID = season.id
                                    }
                                    .id(season.id)
                                }
                            }
                        }
                        .contentMargins(
                            .leading,
                            pageInset,
                            for: .scrollContent
                        )
                        .contentMargins(
                            .trailing,
                            4,
                            for: .scrollContent
                        )
                        .scrollIndicators(.hidden)
                        .scrollClipDisabled()
                        .onChange(
                            of: selectedSeasonID,
                            initial: true
                        ) { _, selectedSeasonID in
                            guard let selectedSeasonID else { return }
                            withAnimation(.easeInOut(duration: 0.3)) {
                                proxy.scrollTo(
                                    selectedSeasonID,
                                    anchor: .center
                                )
                            }
                        }
                    }
                    seasonRailActions
                    }
                    .padding(.trailing, pageInset)

                    if let seasonRequestError {
                    Text(seasonRequestError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.horizontal, pageInset)
                    }
                }

                PlozziOSInlineEpisodeRail(
                    episodes: displayedEpisodes,
                    isLoading: !seasons.isEmpty
                        && selectedSeasonID != nil
                        && displayedEpisodes == nil,
                    currentEpisodeID: initialEpisode?.seasonID == selectedSeasonID
                        ? initialEpisode?.id
                        : nil,
                    onPlay: onPlay
                )
            }
            .onChange(of: seasons.map(\.id), initial: true) { _, ids in
                if selectedSeasonID == nil
                    || !ids.contains(selectedSeasonID ?? "") {
                    selectedSeasonID = ids.first
                }
            }
            .task(id: selectedSeasonID) {
                if let selectedSeasonID {
                    await viewModel.loadEpisodes(for: selectedSeasonID)
                }
                publishPlayTarget()
            }
            .onChange(of: displayedEpisodes, initial: true) {
                publishPlayTarget()
            }
            .alert(
                "Season Download Failed",
                isPresented: Binding(
                    get: { seasonDownloadError != nil },
                    set: { if !$0 { seasonDownloadError = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(seasonDownloadError ?? "")
            }
            .confirmationDialog(
                seasonDownloadPrompt?.title ?? "",
                isPresented: Binding(
                    get: { seasonDownloadPrompt != nil },
                    set: { if !$0 { seasonDownloadPrompt = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let prompt = seasonDownloadPrompt {
                    Button("Download \(prompt.count) Episodes") {
                        seasonDownloadPrompt = nil
                        performSeasonDownload(
                            prompt.season,
                            episodes: prompt.episodes
                        )
                    }
                    Button("Cancel", role: .cancel) {
                        seasonDownloadPrompt = nil
                    }
                }
            } message: {
                if let prompt = seasonDownloadPrompt {
                    Text(prompt.message)
                }
            }
        }
    }

    private var displayedEpisodes: [MediaItem]? {
        if seasons.isEmpty {
            return looseEpisodes
        }
        guard let selectedSeasonID else { return nil }
        return viewModel.episodes(for: selectedSeasonID)
    }

    private var pageInset: CGFloat {
        PlozziOSPageLayout.horizontalInset(for: horizontalSizeClass)
    }

    private var selectedSeason: MediaItem? {
        guard let selectedSeasonID else { return nil }
        return seasons.first { $0.id == selectedSeasonID }
    }

    private var seasonRailActions: some View {
        HStack(spacing: 8) {
            Button {
                beginSeasonDownload()
            } label: {
                if isDownloadingSeason {
                    ProgressView()
                        .frame(width: 44, height: 44)
                } else {
                    Image(systemName: "arrow.down")
                        .font(.headline)
                        .frame(width: 44, height: 44)
                }
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .disabled(
                isDownloadingSeason
                    || selectedSeason == nil
                    || displayedEpisodes?.isEmpty != false
            )
            .accessibilityLabel(
                selectedSeason.map { "Download \($0.title)" }
                    ?? "Download season"
            )

            if let seasonRequestAvailability,
               seasonRequestAvailability.hasSeasonRequestContent {
                PlozziOSSeasonRequestMenu(
                    availability: seasonRequestAvailability,
                    isRequesting: isRequestingSeasons,
                    onRequest: onRequestSeasons
                )
            }
        }
        .fixedSize()
    }

    private func beginSeasonDownload() {
        guard let selectedSeason,
              let displayedEpisodes,
              !displayedEpisodes.isEmpty else {
            return
        }
        // A single episode is a one-tap action; bulk grabs require an explicit
        // "are you sure" so a 300-episode season can't be started by accident.
        if displayedEpisodes.count > 1 {
            seasonDownloadPrompt = PlozziOSSeasonDownloadPrompt(
                season: selectedSeason,
                episodes: displayedEpisodes
            )
        } else {
            performSeasonDownload(selectedSeason, episodes: displayedEpisodes)
        }
    }

    private func performSeasonDownload(
        _ season: MediaItem,
        episodes: [MediaItem]
    ) {
        isDownloadingSeason = true
        Task {
            do {
                _ = try await onDownloadSeason(season, episodes)
            } catch {
                seasonDownloadError = error.localizedDescription
            }
            isDownloadingSeason = false
        }
    }

    private func publishPlayTarget() {
        guard let displayedEpisodes else {
            onPlayTargetChange(nil)
            return
        }
        if initialEpisode?.seasonID == selectedSeasonID,
           let initialID = initialEpisode?.id,
           let loaded = displayedEpisodes.first(where: { $0.id == initialID }) {
            onPlayTargetChange(loaded)
            return
        }
        onPlayTargetChange(SeriesResume.nextUp(in: displayedEpisodes))
    }
}

private enum PlozziOSSeasonDownloadError: LocalizedError {
    case serverUnavailable

    var errorDescription: String? {
        switch self {
        case .serverUnavailable:
            return "The selected server is no longer available."
        }
    }
}

/// Backing data for the "download the whole season?" confirmation. Presented
/// only for multi-episode grabs so a single episode stays a one-tap action.
private struct PlozziOSSeasonDownloadPrompt: Identifiable {
    let season: MediaItem
    let episodes: [MediaItem]

    var id: String { season.id }
    var count: Int { episodes.count }

    var title: String {
        "Download \(season.title)?"
    }

    var message: String {
        var text = "This downloads all \(count) episodes at original quality "
            + "and can use significant storage and data. You can remove them "
            + "anytime from Downloads."
        if let free = Self.freeSpaceText() {
            text += "\n\n\(free) free on this device."
        }
        return text
    }

    /// Best-effort human-readable free space so a bulk grab shows headroom
    /// awareness. Returns `nil` when the capacity can't be read.
    private static func freeSpaceText() -> String? {
        let url = URL.documentsDirectory
        guard let values = try? url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ), let capacity = values.volumeAvailableCapacityForImportantUsage
        else {
            return nil
        }
        return capacity.formatted(.byteCount(style: .file))
    }
}

private struct PlozziOSSeasonButton: View {
    @Environment(\.themePalette) private var palette

    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .foregroundStyle(
                    isSelected
                        ? palette.backgroundBase
                        : palette.primaryText
                )
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(
                    isSelected
                        ? palette.primaryText
                        : palette.cardSurface.opacity(0.92),
                    in: Capsule()
                )
                .overlay {
                    if !isSelected {
                        Capsule()
                            .strokeBorder(
                                palette.primaryText.opacity(0.2),
                                lineWidth: 1
                            )
                    }
                }
        }
        .buttonStyle(.plain)
    }
}

private struct PlozziOSInlineEpisodeRail: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let episodes: [MediaItem]?
    let isLoading: Bool
    var currentEpisodeID: String? = nil
    let onPlay: (MediaItem, Bool) -> Void

    var body: some View {
        if isLoading {
            ProgressView("Loading episodes…")
                .frame(minHeight: 180)
        } else if let episodes, episodes.isEmpty {
            ContentUnavailableView(
                "No episodes",
                systemImage: "play.rectangle"
            )
            .frame(minHeight: 180)
        } else if let episodes {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(episodes) { episode in
                            PlozziOSInlineEpisodeEntry(
                                episode: episode,
                                episodes: episodes,
                                onPlay: onPlay
                            )
                            .id(episode.id)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned(limitBehavior: .never))
                .contentMargins(
                    .horizontal,
                    PlozziOSPageLayout.horizontalInset(
                        for: horizontalSizeClass
                    ),
                    for: .scrollContent
                )
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
                .onAppear {
                    guard let currentEpisodeID else { return }
                    proxy.scrollTo(currentEpisodeID, anchor: .leading)
                }
            }
        }
    }
}

private struct PlozziOSInlineEpisodeEntry: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.plozzCardStyle) private var cardStyle
    @Environment(\.plozzMetrics) private var metrics
    @Environment(PlozziOSAppModel.self) private var appModel
    @State private var downloadRecord: DownloadedMediaRecord?
    @State private var downloadError: String?

    let episode: MediaItem
    let episodes: [MediaItem]
    let onPlay: (MediaItem, Bool) -> Void

    @ViewBuilder
    var body: some View {
        if cardStyle == .framed {
            content
                .plozzFramedMediaCard(
                    innerCornerRadius: PlozzTheme.Metrics.mediumMediaCornerRadius
                )
                .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                onPlay(episode, false)
            } label: {
                episodeArtwork
            }
            .buttonStyle(.plain)
            .overlay(alignment: .topLeading) {
                Menu {
                    episodeMenuActions
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .padding(4)
                .accessibilityLabel("More actions for \(episode.title)")
            }
            .overlay(alignment: .topTrailing) {
                MediaCardPlaybackIndicators(
                    item: episode,
                    showsProgressBar: false,
                    badgeInset: 8
                )
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: PlozzTheme.Metrics.mediumMediaCornerRadius,
                        style: .continuous
                    )
                )
            }
            .overlay(alignment: .bottom) {
                HStack(alignment: .center, spacing: 8) {
                    EpisodeWatchStatePill(
                        item: episode,
                        showsWatched: false,
                        showsBackground: false
                    )
                    .font(.caption.weight(.semibold))
                    .frame(height: 24)
                    Spacer(minLength: 8)
                    if let record = currentDownloadRecord {
                        PlozziOSEpisodeDownloadIndicator(record: record)
                            .frame(width: 24, height: 24)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }

            VStack(alignment: .leading, spacing: 3) {
                if let number = episode.episodeNumber {
                    Text("Episode \(number)")
                        .font(.caption2.weight(.semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                }
                Text(episode.title)
                    .font(.headline)
                    .lineLimit(1)
                if let overview = episode.overview, !overview.isEmpty {
                    Text(overview.overviewMarkdown ?? AttributedString(overview))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(
                            maxWidth: .infinity,
                            minHeight: 40,
                            alignment: .topLeading
                        )
                } else {
                    Color.clear.frame(height: 40).accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, metrics.landscapeCaptionInset)
        }
        .frame(width: cardWidth, alignment: .leading)
        .padding(cardStyle == .framed ? 10 : 0)
        .contextMenu { episodeMenuActions }
        .task(id: episode.id) {
            downloadRecord = await appModel.downloads.record(for: episode)
        }
        .alert(
            "Download Failed",
            isPresented: Binding(
                get: { downloadError != nil },
                set: { if !$0 { downloadError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(downloadError ?? "")
        }
    }

    private var cardWidth: CGFloat {
        horizontalSizeClass == .regular ? 360 : 300
    }

    private var episodeArtwork: some View {
        AsyncImage(url: episode.backdropURL ?? episode.posterURL) { image in
            image
                .resizable()
                .scaledToFill()
        } placeholder: {
            Rectangle()
                .fill(.secondary.opacity(0.14))
        }
        .frame(width: cardWidth, height: cardWidth * 9 / 16)
        .overlay {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.5), location: 0),
                    .init(color: .clear, location: 0.34),
                    .init(color: .clear, location: 0.62),
                    .init(color: .black.opacity(0.58), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)
        }
        .clipShape(
            RoundedRectangle(
                cornerRadius: PlozzTheme.Metrics.mediumMediaCornerRadius,
                style: .continuous
            )
        )
        .plozzMediaEdge(
            cornerRadius: PlozzTheme.Metrics.mediumMediaCornerRadius
        )
    }

    @ViewBuilder
    private var episodeMenuActions: some View {
        ForEach(mediaActions) { action in
            Button(action.title, systemImage: action.systemImage) {
                appModel.mediaItemActionHandler.perform(
                    action,
                    on: episode,
                    context: MediaItemActionContext(orderedSiblings: episodes)
                )
            }
        }
        if !mediaActions.isEmpty {
            Divider()
        }
        downloadMenuAction
    }

    @ViewBuilder
    private var downloadMenuAction: some View {
        switch currentDownloadRecord?.status {
        case .queued, .downloading:
            Button("Pause Download", systemImage: "pause.circle") {
                Task { await pauseDownload() }
            }
        case .paused, .failed:
            Button("Resume Download", systemImage: "arrow.clockwise.circle") {
                Task { await resumeDownload() }
            }
        case .completed:
            Button(
                "Remove Download",
                systemImage: "trash",
                role: .destructive
            ) {
                Task { await removeDownload() }
            }
        case nil:
            Button("Download Episode", systemImage: "arrow.down.circle") {
                Task { await startDownload() }
            }
        }
    }

    private var mediaActions: [MediaItemAction] {
        appModel.mediaItemActionHandler.actions(
            for: episode,
            context: MediaItemActionContext(orderedSiblings: episodes)
        )
        .filter { !$0.isNavigation }
    }

    private var currentDownloadRecord: DownloadedMediaRecord? {
        guard let downloadRecord else { return nil }
        return appModel.downloads.records.first {
            $0.identityKey == downloadRecord.identityKey
        } ?? downloadRecord
    }

    private func startDownload() async {
        do {
            guard let provider = appModel.provider(for: episode) else {
                downloadError = "The selected server is no longer available."
                return
            }
            downloadRecord = try await appModel.downloads.enqueue(
                item: episode,
                provider: provider
            )
        } catch {
            downloadError = error.localizedDescription
        }
    }

    private func pauseDownload() async {
        guard let record = currentDownloadRecord else { return }
        await appModel.downloads.pause(record)
        downloadRecord = appModel.downloads.records.first {
            $0.identityKey == record.identityKey
        }
    }

    private func resumeDownload() async {
        guard let record = currentDownloadRecord else { return }
        await appModel.downloads.resume(record)
        downloadRecord = appModel.downloads.records.first {
            $0.identityKey == record.identityKey
        }
    }

    private func removeDownload() async {
        guard let record = currentDownloadRecord else { return }
        await appModel.downloads.remove(record)
        downloadRecord = nil
    }
}

/// Compact per-episode download status overlaid on the thumbnail. Per the
/// desired read: a neutral **white progress ring with no center glyph** while
/// downloading (unmistakably progress, not a button), and a **filled gray
/// down-arrow** when complete (a settled status, not an action). Hidden when the
/// episode isn't downloaded — download itself is started from the ⋯ menu.
private struct PlozziOSEpisodeDownloadIndicator: View {
    let record: DownloadedMediaRecord
    private let size: CGFloat = 22

    var body: some View {
        switch record.status {
        case .completed:
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: size))
                .foregroundStyle(.white.opacity(0.85))
                .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
                .accessibilityLabel("Downloaded")
        case .downloading, .queued:
            ring(fraction: record.fractionCompleted ?? 0)
                .accessibilityLabel("Downloading")
        case .paused:
            ring(fraction: record.fractionCompleted ?? 0, dimmed: true)
                .accessibilityLabel("Download paused")
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: size))
                .foregroundStyle(.orange)
                .accessibilityLabel("Download failed")
        }
    }

    private func ring(fraction: Double, dimmed: Bool = false) -> some View {
        // Match the filled `arrow.down.circle.fill` glyph's visible circle (which
        // is inset from its point size) and use a heavier stroke so the ring reads
        // at the same weight as the icon rather than thin-and-oversized.
        let diameter = size * 0.86
        let lineWidth: CGFloat = 4
        return ZStack {
            Circle()
                .stroke(Color.white.opacity(0.28), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.02, fraction))
                .stroke(
                    Color.white.opacity(dimmed ? 0.5 : 1),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.25), value: fraction)
        }
        .frame(width: diameter, height: diameter)
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
    }
}

private struct PlozziOSCastSection: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    // Scales the trailing whitespace with the OS text size so the space under the
    // (variably wrapped) cast names stays proportional at every Dynamic Type level,
    // mirroring the space above the About header rather than a fixed gap.
    @ScaledMetric(relativeTo: .subheadline) private var regularBottomPadding: CGFloat = 32
    @ScaledMetric(relativeTo: .subheadline) private var compactBottomPadding: CGFloat = 24
    let people: [MediaPerson]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cast")
                .font(.title2.bold())
                .padding(.horizontal, pageInset)

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 20) {
                    ForEach(people.prefix(20)) { person in
                        VStack(alignment: .leading, spacing: 8) {
                            AsyncImage(url: person.imageURL) { image in
                                image
                                    .resizable()
                                    .scaledToFill()
                            } placeholder: {
                                Circle()
                                    .fill(.secondary.opacity(0.14))
                                    .overlay {
                                        Image(systemName: "person.fill")
                                            .foregroundStyle(.secondary)
                                    }
                            }
                            .frame(width: 164, height: 164)
                            .clipShape(Circle())
                            .frame(width: 164, alignment: .top)

                            Text(person.name)
                                .font(.subheadline.weight(.semibold))
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(
                                    maxWidth: .infinity,
                                    alignment: .top
                                )
                            if let role = person.role {
                                Text(role)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(
                                        horizontal: false,
                                        vertical: true
                                    )
                                    .frame(
                                        maxWidth: .infinity,
                                        alignment: .top
                                    )
                            }
                        }
                        .frame(width: 164, alignment: .top)
                        .multilineTextAlignment(.center)
                    }
                }
            }
            .contentMargins(
                .horizontal,
                pageInset,
                for: .scrollContent
            )
            .scrollIndicators(.hidden)
        }
        // Symmetric scaled whitespace above and below the cast rail so it sits with
        // balanced breathing room between the hero and the info band — and the gap
        // under the (variably wrapped) names mirrors the gap over the About header.
        .padding(.vertical, verticalPadding)
    }

    private var verticalPadding: CGFloat {
        horizontalSizeClass == .compact ? compactBottomPadding : regularBottomPadding
    }

    private var pageInset: CGFloat {
        PlozziOSPageLayout.horizontalInset(for: horizontalSizeClass)
    }
}
#endif
