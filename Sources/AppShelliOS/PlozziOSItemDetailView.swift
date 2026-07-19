#if os(iOS)
import AppRuntime
import CoreModels
import FeatureHomeCore
import MediaDownloads
import SeerService
import SwiftUI

struct PlozziOSItemDetailView: View {
    @Environment(PlozziOSAppModel.self) private var appModel
    @State private var viewModel: ItemDetailViewModel
    @State private var playbackRequest: PlozziOSPlaybackRequest?
    @State private var downloadRecord: DownloadedMediaRecord?
    @State private var downloadError: String?
    @State private var requestError: String?
    @State private var isRequesting = false
    @State private var requestConfirmationItem: MediaItem?
    @State private var requestStatusOverride: MediaAvailabilityStatus?
    @State private var sourceOverride: String?
    @State private var versionOverride: String?
    private let seerService: SeerService?
    private let isDiscoveryItem: Bool
    private let initialSources: [MediaSourceRef]
    private let capabilities = MediaCapabilities.detected()

    init(
        appModel: PlozziOSAppModel,
        provider: any MediaProvider,
        item: MediaItem,
        seerService: SeerService? = nil,
        originSourceAccountID: String? = nil
    ) {
        self.seerService = seerService
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
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.load() }
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
                set: { if !$0 { requestConfirmationItem = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Request as Administrator") {
                guard let item = requestConfirmationItem else { return }
                requestConfirmationItem = nil
                Task { await request(item) }
            }
            Button("Cancel", role: .cancel) {
                requestConfirmationItem = nil
            }
        } message: {
            Text(
                "This profile isn’t linked to a Seerr user. "
                    + "The request will use the unrestricted administrator account."
            )
        }
    }

    private func detailContent(_ detail: ItemDetailViewModel.Detail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PlozziOSDetailHero(item: detail.item)
                sourceAndVersionControls(for: detail.item)

                if isDiscoveryItem {
                    PlozziOSRequestAction(
                        item: detail.item,
                        availability: requestStatusOverride ?? detail.item.availability ?? .unknown,
                        isRequesting: isRequesting,
                        errorMessage: requestError,
                        actingName: appModel.activeSeerrUserName,
                        onRequest: beginRequest
                    )
                } else {
                    PlozziOSDetailManagementActions(
                        item: detail.item,
                        handler: appModel.mediaItemActionHandler
                    )
                    if detail.item.kind == .movie || detail.item.kind == .episode {
                        let playableItem = playbackItem(for: detail.item)
                        PlozziOSPlaybackActions(item: playableItem, onPlay: play)
                        PlozziOSDownloadAction(
                            item: playableItem,
                            record: currentDownloadRecord,
                            errorMessage: downloadError,
                            onDownload: { Task { await download(playableItem) } },
                            onPause: { Task { await pauseDownload() } },
                            onResume: { Task { await resumeDownload() } },
                            onRemove: { Task { await removeDownload(playableItem) } }
                        )
                    }
                }

                if detail.item.kind == .series, !detail.children.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Seasons")
                            .font(.title2.bold())

                        ForEach(detail.children) { season in
                            NavigationLink {
                                PlozziOSSeasonEpisodesView(
                                    viewModel: viewModel,
                                    season: season,
                                    onPlay: play
                                )
                            } label: {
                                PlozziOSSeasonRow(season: season)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if !detail.item.people.filter(\.isCast).isEmpty {
                    PlozziOSCastSection(people: detail.item.people.filter(\.isCast))
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
        .navigationTitle(detail.item.title)
        .task(id: downloadLookupID(for: detail.item)) {
            downloadRecord = await appModel.downloads.record(
                for: playbackItem(for: detail.item)
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .mediaItemDidMutate)) { note in
            guard let mutation = MediaItemMutation.from(note) else { return }
            viewModel.applyWatchedState(mutation)
        }
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
        return DetailPlaybackSelection.playItem(
            for: item,
            sources: sources,
            activeAccountID: source?.accountID,
            versionID: versionID,
            explicit: viewModel.isLibraryOriginPinned
                || sourceOverride != nil
                || versionOverride != nil
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

    private func beginRequest(_ item: MediaItem) {
        if appModel.activeSeerrUserID == nil, appModel.profiles.profiles.count > 1 {
            requestConfirmationItem = item
        } else {
            Task { await request(item) }
        }
    }

    private func request(_ item: MediaItem) async {
        guard let seerService else {
            requestError = "Connect Overseerr or Jellyseerr in Settings first."
            return
        }
        isRequesting = true
        requestError = nil
        defer { isRequesting = false }
        let outcome = await seerService.request(
            item,
            actingUserID: appModel.activeSeerrUserID
        )
        switch outcome {
        case let .success(status):
            requestStatusOverride = status
            await viewModel.load()
        case let .failure(reason):
            requestError = requestFailureMessage(reason)
        }
    }

    private func requestFailureMessage(_ reason: SeerRequestFailure) -> String {
        switch reason {
        case .noDefaults:
            return "No default server or quality profile is configured for this user."
        case .noPermission:
            return "This user doesn’t have permission to make that request."
        case .quotaExceeded:
            return "This user has reached their request limit."
        case .alreadyRequested:
            return "This title has already been requested."
        case .invalidActingUser:
            return "The linked Seerr user no longer exists. Update the profile mapping in Settings."
        case .unreachable:
            return "Couldn’t reach the Seerr server."
        case let .unknown(message):
            return message ?? "The request failed."
        }
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

    var body: some View {
        HStack(spacing: 12) {
            if sources.count > 1 {
                Menu {
                    ForEach(sources) { source in
                        Button {
                            onSelectSource(source.accountID)
                        } label: {
                            selectionLabel(
                                source.displayName,
                                selected: source.accountID == selectedSourceID
                            )
                        }
                    }
                } label: {
                    Label(
                        selectedSource?.displayName ?? "Server",
                        systemImage: "server.rack"
                    )
                }
                .buttonStyle(.bordered)
            }

            if versions.count > 1 {
                Menu {
                    ForEach(versions) { version in
                        Button {
                            onSelectVersion(version.id)
                        } label: {
                            selectionLabel(
                                version.displayLabel,
                                selected: version.id == selectedVersionID
                            )
                        }
                    }
                } label: {
                    Label(
                        selectedVersion?.displayLabel ?? "Version",
                        systemImage: "film.stack"
                    )
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var selectedSource: MediaSourceRef? {
        sources.first { $0.accountID == selectedSourceID }
    }

    private var selectedVersion: MediaVersion? {
        versions.first { $0.id == selectedVersionID }
    }

    @ViewBuilder
    private func selectionLabel(_ title: String, selected: Bool) -> some View {
        if selected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
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

private struct PlozziOSPlaybackActions: View {
    let item: MediaItem
    let onPlay: (MediaItem, Bool) -> Void

    var body: some View {
        HStack {
            Button {
                onPlay(item, false)
            } label: {
                Label(primaryTitle, systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            if hasResumePosition {
                Button {
                    onPlay(item, true)
                } label: {
                    Label("Start Over", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)
            }
        }
        .controlSize(.large)
    }

    private var hasResumePosition: Bool {
        (item.resumePosition ?? 0) > 1
    }

    private var primaryTitle: LocalizedStringKey {
        hasResumePosition ? "Resume" : "Play"
    }
}

private struct PlozziOSDetailHero: View {
    let item: MediaItem

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ZStack(alignment: .bottomLeading) {
                AsyncImage(url: item.backdropURL ?? item.posterURL) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    Rectangle()
                        .fill(.secondary.opacity(0.14))
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipped()

                LinearGradient(
                    colors: [.clear, .black.opacity(0.78)],
                    startPoint: .center,
                    endPoint: .bottom
                )

                Text(item.title)
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)
                    .padding()
            }
            .clipShape(RoundedRectangle(cornerRadius: 20))

            if !metadata.isEmpty {
                Text(metadata.joined(separator: "  •  "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let overview = item.overview, !overview.isEmpty {
                Text(overview)
                    .font(.body)
                    .textSelection(.enabled)
            }

            if !item.genres.isEmpty {
                Text(item.genres.prefix(4).joined(separator: "  •  "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var metadata: [String] {
        var values: [String] = []
        if let year = item.productionYear {
            values.append(year.formatted())
        }
        if let rating = item.officialRating, !rating.isEmpty {
            values.append(rating)
        }
        if let runtime = item.runtime, runtime > 0 {
            let minutes = Int(runtime / 60)
            values.append("\(minutes / 60)h \(minutes % 60)m")
        }
        return values
    }
}

private struct PlozziOSSeasonRow: View {
    let season: MediaItem

    var body: some View {
        HStack(spacing: 14) {
            AsyncImage(url: season.posterURL) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                Rectangle()
                    .fill(.secondary.opacity(0.14))
                    .overlay {
                        Image(systemName: "rectangle.stack")
                            .foregroundStyle(.secondary)
                    }
            }
            .frame(width: 72, height: 108)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            Text(season.title)
                .font(.headline)

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

private struct PlozziOSSeasonEpisodesView: View {
    let viewModel: ItemDetailViewModel
    let season: MediaItem
    let onPlay: (MediaItem, Bool) -> Void

    var body: some View {
        Group {
            if let episodes = viewModel.episodes(for: season.id) {
                if episodes.isEmpty {
                    ContentUnavailableView(
                        "No episodes",
                        systemImage: "play.rectangle"
                    )
                } else {
                    List(episodes) { episode in
                        HStack {
                            Button {
                                onPlay(episode, false)
                            } label: {
                                PlozziOSEpisodeRow(episode: episode)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                ForEach(actions(for: episode, episodes: episodes)) { action in
                                    Button(action.title, systemImage: action.systemImage) {
                                        appModel.mediaItemActionHandler.perform(
                                            action,
                                            on: episode,
                                            context: MediaItemActionContext(
                                                orderedSiblings: episodes
                                            )
                                        )
                                    }
                                }
                            }

                            PlozziOSEpisodeDownloadButton(
                                episode: episode
                            )
                        }
                    }
                    .listStyle(.plain)
                }
            } else {
                ProgressView("Loading episodes…")
            }
        }
        .navigationTitle(season.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.loadEpisodes(for: season.id) }
        .onReceive(NotificationCenter.default.publisher(for: .mediaItemDidMutate)) { note in
            guard let mutation = MediaItemMutation.from(note) else { return }
            viewModel.applyWatchedState(mutation)
        }
    }

    @Environment(PlozziOSAppModel.self) private var appModel

    private func actions(
        for episode: MediaItem,
        episodes: [MediaItem]
    ) -> [MediaItemAction] {
        appModel.mediaItemActionHandler.actions(
            for: episode,
            context: MediaItemActionContext(orderedSiblings: episodes)
        )
        .filter { !$0.isNavigation }
    }
}

private struct PlozziOSEpisodeDownloadButton: View {
    @Environment(PlozziOSAppModel.self) private var appModel
    @State private var record: DownloadedMediaRecord?
    @State private var errorMessage: String?

    let episode: MediaItem

    var body: some View {
        Button(action: toggleDownload) {
            Group {
                switch currentRecord?.status {
                case .downloading, .queued:
                    ProgressView()
                case .paused, .failed:
                    Image(systemName: "arrow.clockwise.circle")
                case .completed:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case nil:
                    Image(systemName: "arrow.down.circle")
                }
            }
            .frame(width: 44, height: 44)
        }
        .buttonStyle(.borderless)
        .disabled(currentRecord?.status == .completed)
        .contextMenu {
            if let currentRecord {
                Button("Remove Download", systemImage: "trash", role: .destructive) {
                    Task {
                        await appModel.downloads.remove(currentRecord)
                        record = nil
                    }
                }
            }
        }
        .task(id: episode.id) {
            record = await appModel.downloads.record(for: episode)
        }
        .alert(
            "Download Failed",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .accessibilityLabel(accessibilityLabel)
    }

    private var currentRecord: DownloadedMediaRecord? {
        guard let record else { return nil }
        return appModel.downloads.records.first {
            $0.identityKey == record.identityKey
        } ?? record
    }

    private var accessibilityLabel: String {
        switch currentRecord?.status {
        case .downloading, .queued: "Pause download"
        case .paused, .failed: "Resume download"
        case .completed: "Downloaded"
        case nil: "Download episode"
        }
    }

    private func toggleDownload() {
        Task {
            do {
                if let currentRecord {
                    switch currentRecord.status {
                    case .downloading, .queued:
                        await appModel.downloads.pause(currentRecord)
                    case .paused, .failed:
                        await appModel.downloads.resume(currentRecord)
                    case .completed:
                        break
                    }
                } else {
                    guard let provider = appModel.provider(for: episode) else {
                        errorMessage = "The selected server is no longer available."
                        return
                    }
                    record = try await appModel.downloads.enqueue(
                        item: episode,
                        provider: provider
                    )
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct PlozziOSEpisodeRow: View {
    let episode: MediaItem

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            AsyncImage(url: episode.backdropURL ?? episode.posterURL) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                Rectangle()
                    .fill(.secondary.opacity(0.14))
            }
            .frame(width: 120, height: 68)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 5) {
                Text(episode.episodeLabel)
                    .font(.headline)
                if let overview = episode.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct PlozziOSCastSection: View {
    let people: [MediaPerson]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cast")
                .font(.title2.bold())

            ScrollView(.horizontal) {
                LazyHStack(spacing: 14) {
                    ForEach(people.prefix(20)) { person in
                        VStack(alignment: .leading, spacing: 6) {
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
                            .frame(width: 82, height: 82)
                            .clipShape(Circle())

                            Text(person.name)
                                .font(.caption.weight(.medium))
                                .lineLimit(2)
                            if let role = person.role {
                                Text(role)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .frame(width: 96, alignment: .leading)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }
}

private extension MediaItem {
    var episodeLabel: String {
        if let episodeNumber {
            return "Episode \(episodeNumber): \(title)"
        }
        return title
    }
}
#endif
