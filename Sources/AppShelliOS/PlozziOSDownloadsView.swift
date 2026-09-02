#if os(iOS)
import CoreModels
import CoreUI
import MediaDownloads
import SwiftUI
import UIKit

struct PlozziOSDownloadsView: View {
    @Bindable var model: PlozziOSDownloadsModel
    let appModel: PlozziOSAppModel
    let onShowSettings: () -> Void

    @State private var pendingBulkDeletion: PlozziOSDownloadsBulkDeletion?

    var body: some View {
        let library = model.library
        Group {
            if let error = model.initializationError {
                ContentUnavailableView(
                    "Downloads Unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
            } else if library.isEmpty {
                ContentUnavailableView(
                    "No Downloads",
                    systemImage: "arrow.down.circle",
                    description: Text(
                        "Download a movie or episode from its detail page to watch offline."
                    )
                )
            } else {
                libraryList(library)
            }
        }
        .navigationTitle("Downloads")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    PlozziOSDownloadSettingsView(model: model)
                } label: {
                    Label("Download Settings", systemImage: "gearshape")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                PlozziOSSettingsAvatarButton(size: 36, action: onShowSettings)
            }
        }
        .confirmationDialog(
            pendingBulkDeletion.map { Text($0.title) } ?? Text(verbatim: ""),
            isPresented: Binding(
                get: { pendingBulkDeletion != nil },
                set: { if !$0 { pendingBulkDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let deletion = pendingBulkDeletion {
                Button(deletion.confirmLabel, role: .destructive) {
                    let reevaluate = deletion.reevaluatesActiveAtConfirm
                    let records = deletion.records
                    pendingBulkDeletion = nil
                    Task {
                        if reevaluate {
                            await model.cancelActiveTransfers()
                        } else {
                            await model.remove(records)
                        }
                    }
                }
                Button("Cancel", role: .cancel) { pendingBulkDeletion = nil }
            }
        } message: {
            if let deletion = pendingBulkDeletion {
                Text(deletion.message)
            }
        }
    }

    private func libraryList(_ library: PlozziOSDownloadLibrary) -> some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 16) {
                    if model.hasActiveTransfers {
                        activeTransfersHeader
                    }
                    LazyVGrid(
                        columns: Self.columns(for: proxy.size.width),
                        spacing: 20
                    ) {
                        ForEach(library.entries) { entry in
                            switch entry {
                            case let .movie(movie):
                                movieTile(movie)
                            case let .show(show):
                                showTile(show)
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
        }
    }

    private var activeTransfersHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(model.activeTransfers.count) active")
                    .font(.headline)
                Text(activeTransferSummary)
                    .font(.caption)
                    .plozzForeground(.secondary)
            }
            Spacer()
            if model.activeTransfers.contains(where: {
                $0.status == .downloading
                    || $0.status == .preparing
                    || $0.status == .queued
            }) {
                Button("Pause All", systemImage: "pause.fill") {
                    Task { await model.pauseAllActive() }
                }
            } else {
                Button("Resume All", systemImage: "play.fill") {
                    Task { await model.resumeAllPaused() }
                }
            }
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var activeTransferSummary: String {
        var parts = [model.activeLimitDescription]
        if model.aggregateBytesPerSecond > 0 {
            parts.insert(
                model.aggregateBytesPerSecond.formatted(.byteCount(style: .file))
                    + "/s",
                at: 0
            )
        }
        if let eta = model.aggregateETA {
            parts.append(
                Duration.seconds(eta).formatted(
                    .units(
                        allowed: [.hours, .minutes],
                        width: .abbreviated,
                        maximumUnitCount: 2
                    )
                ) + " remaining"
            )
        }
        return parts.joined(separator: " • ")
    }

    /// Landscape download tiles: one column on a compact phone, two on an iPad in
    /// portrait, three on a wide iPad — using the real estate the old full-width
    /// rows left empty.
    private static func columns(for width: CGFloat) -> [GridItem] {
        let count: Int
        switch width {
        case ..<560: count = 1
        case ..<1100: count = 2
        default: count = 3
        }
        return Array(repeating: GridItem(.flexible(), spacing: 20), count: count)
    }

    @ViewBuilder
    private func movieTile(_ movie: PlozziOSDownloadedMovie) -> some View {
        let record = movie.record
        tileCard(
            menu: {
                transferMenuActions(for: record)
                Button("Remove", systemImage: "trash", role: .destructive) {
                    Task { await model.remove(record) }
                }
            },
            accessibilityTitle: record.snapshot.title
        ) {
            DownloadRowLink(record: record, model: model, appModel: appModel) {
                DownloadTileContent(
                    title: record.snapshot.title,
                    subtitle: DownloadFormatting.status(for: record),
                    subtitleColor: DownloadFormatting.statusColor(for: record),
                    fraction: DownloadFormatting.activeFraction(for: record),
                    failure: DownloadFormatting.failure(for: record),
                    artworkURL: model.artworkURL(for: record),
                    kind: record.snapshot.kind
                )
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func showTile(_ show: PlozziOSDownloadedShow) -> some View {
        tileCard(
            menu: {
                Button("Remove", systemImage: "trash", role: .destructive) {
                    pendingBulkDeletion = .show(show)
                }
            },
            accessibilityTitle: show.title
        ) {
            NavigationLink {
                PlozziOSDownloadedShowView(
                    showID: show.id,
                    model: model,
                    appModel: appModel
                )
            } label: {
                DownloadTileContent(
                    title: show.title,
                    subtitle: Text(DownloadFormatting.showSubtitle(
                        episodeCount: show.episodeCount,
                        seasonCount: show.seasons.count,
                        bytes: show.totalBytes
                    )),
                    subtitleColor: .secondary,
                    fraction: nil,
                    failure: nil,
                    artworkURL: show.artworkRecord.flatMap(model.artworkURL(for:)),
                    kind: .series
                )
            }
            .buttonStyle(.plain)
        }
    }

    /// Wraps a tile's navigation link with a "⋯" actions menu placed in the same
    /// top-leading slot the detail-page episode cards use, plus a matching
    /// long-press context menu. The menu is a sibling *above* the link so its taps
    /// never trigger navigation.
    @ViewBuilder
    private func tileCard<Menu: View, Card: View>(
        @ViewBuilder menu: () -> Menu,
        accessibilityTitle: String,
        @ViewBuilder card: () -> Card
    ) -> some View {
        let menuContent = menu()
        ZStack(alignment: .topLeading) {
            card()
                .contextMenu { menuContent }
            SwiftUI.Menu {
                menuContent
            } label: {
                Image(systemName: "ellipsis")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .padding(4)
            .accessibilityLabel("More actions for \(accessibilityTitle)")
        }
    }

    @ViewBuilder
    private func transferMenuActions(
        for record: DownloadedMediaRecord
    ) -> some View {
        switch record.status {
        case .preparing, .downloading, .queued:
            Button("Pause", systemImage: "pause") {
                Task { await model.pause(record) }
            }
        case .paused, .failed:
            Button("Resume", systemImage: "play") {
                Task { await model.resume(record) }
            }
        case .completed:
            EmptyView()
        }
    }
}

/// A device storage capacity bar for the Downloads page: shows how much space
/// Plozz downloads use relative to what's used by other apps and what's free,
/// so "Delete All" sits next to a clear picture of the impact. Falls back to a
/// plain size line when the volume capacity can't be read.
struct PlozziOSDownloadsStorageBar: View {
    let downloadsBytes: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let capacity = Self.deviceCapacity() {
                let total = max(1, Double(capacity.total))
                let downloads = min(Double(downloadsBytes), total)
                let free = min(Double(capacity.free), total - downloads)
                let other = max(0, total - free - downloads)

                GeometryReader { proxy in
                    let width = proxy.size.width
                    HStack(spacing: 1.5) {
                        segment(width: width * other / total, color: .secondary.opacity(0.35))
                        segment(width: width * downloads / total, color: .accentColor, minWidth: downloadsBytes > 0 ? 3 : 0)
                        segment(width: width * free / total, color: .secondary.opacity(0.12))
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 10)

                HStack(spacing: 14) {
                    legendDot(color: .accentColor, label: "Downloads \(DownloadFormatting.byteText(downloadsBytes))")
                    Spacer(minLength: 0)
                    Text("\(DownloadFormatting.byteText(capacity.free)) free")
                        .font(.caption)
                        .plozzForeground(.secondary)
                }
            } else {
                Text("\(DownloadFormatting.byteText(downloadsBytes)) used by downloads")
                    .font(.caption)
                    .plozzForeground(.secondary)
            }
        }
        .padding(.vertical, 6)
    }

    private func segment(width: CGFloat, color: Color, minWidth: CGFloat = 0) -> some View {
        Rectangle()
            .fill(color)
            .frame(width: max(minWidth, width))
    }

    private func legendDot(color: Color, label: LocalizedStringResource) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
                .font(.caption)
                .plozzForeground(.secondary)
        }
    }

    private static func deviceCapacity() -> (total: Int64, free: Int64)? {
        let url = URL.documentsDirectory
        guard let values = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ]),
            let total = values.volumeTotalCapacity,
            let free = values.volumeAvailableCapacityForImportantUsage
        else {
            return nil
        }
        return (Int64(total), free)
    }
}

/// A single source of truth for status/size text so movie rows, episode rows,
/// and show rows read identically.
enum DownloadFormatting {
    static func status(for record: DownloadedMediaRecord) -> Text {
        let base: Text
        switch record.status {
        case .queued: base = Text("Queued")
        case .preparing: base = Text("Preparing on server")
        case .downloading:
            if let fraction = record.fractionCompleted {
                base = Text(
                    fraction,
                    format: .percent.precision(.fractionLength(0))
                )
            } else {
                base = Text("Downloading")
            }
        case .paused: base = Text("Paused")
        case .completed:
            base = Text("Available offline • \(byteText(record.bytesDownloaded))")
        case .failed: base = Text("Failed")
        }
        // Several versions of one title can now be downloaded side by side, so
        // the row has to say WHICH file it is or two entries look identical.
        // The label is pinned at download time because the server's version list
        // isn't reachable offline.
        guard let version = record.versionLabel, !version.isEmpty else {
            return base
        }
        return Text(verbatim: "\(version) • ") + base
    }

    static func statusColor(for record: DownloadedMediaRecord) -> Color {
        switch record.status {
        case .completed: .green
        case .failed: .red
        default: .secondary
        }
    }

    static func activeFraction(for record: DownloadedMediaRecord) -> Double? {
        guard record.status == .downloading
                || record.status == .preparing
                || record.status == .queued else {
            return nil
        }
        return record.fractionCompleted
    }

    static func failure(for record: DownloadedMediaRecord) -> String? {
        record.status == .failed ? record.failureReason : nil
    }

    /// Both forms are whole sentences so translators can reorder them, and both
    /// counts are real placeholders so the catalog can carry plural variations.
    static func showSubtitle(
        episodeCount: Int,
        seasonCount: Int,
        bytes: Int64
    ) -> LocalizedStringResource {
        if seasonCount > 1 {
            return "\(episodeCount) episodes • \(seasonCount) seasons • \(byteText(bytes))"
        }
        return "\(episodeCount) episodes • \(byteText(bytes))"
    }

    static func byteText(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }

    /// A compact episode label for rows inside a season section, e.g.
    /// "E5 · The Battle" (the season is already the section header).
    static func episodeLabel(for record: DownloadedMediaRecord) -> String {
        if let episode = record.snapshot.episodeNumber {
            return "E\(episode) · \(record.snapshot.title)"
        }
        return record.snapshot.title
    }
}

/// Wraps row content in a detail-page link when the record maps back to a live
/// provider item; otherwise shows the content inert (e.g. a stale source).
struct DownloadRowLink<Content: View>: View {
    let record: DownloadedMediaRecord
    let model: PlozziOSDownloadsModel
    let appModel: PlozziOSAppModel
    @ViewBuilder let content: () -> Content

    var body: some View {
        if let item = model.playbackItem(for: record) ?? model.detailItem(for: record),
           let provider = appModel.provider(for: item) {
            NavigationLink {
                PlozziOSItemDetailView(
                    appModel: appModel,
                    provider: provider,
                    item: item,
                    seerService: appModel.seerService
                )
            } label: {
                content()
            }
        } else {
            content()
        }
    }
}

struct DownloadRowContent: View {
    /// Media title and a formatted status line — both provider/derived content.
    let title: String   // l10n:content — media title from the server
    let subtitle: Text
    let subtitleColor: Color
    let fraction: Double?
    let failure: String?
    let artworkURL: URL?
    let kind: MediaItemKind

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            DownloadArtwork(url: artworkURL, kind: kind)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                    .lineLimit(2)
                subtitle
                    .font(.caption)
                    .foregroundStyle(subtitleColor)
                if let fraction {
                    ProgressView(value: fraction)
                }
                if let failure {
                    Text(failure)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

/// A landscape download tile that shares the app's media-card chrome: the same
/// concentric framed surface (`plozzFramedMediaCard`), media edge, corner radius,
/// and caption insets the Home landscape library cards and detail episode cards
/// use — so downloads read as first-class cards, not a bespoke list.
struct DownloadTileContent: View {
    @Environment(\.plozzCardStyle) private var cardStyle
    @Environment(\.plozzMetrics) private var metrics
    @Environment(\.themePalette) private var palette
    /// Media title and a formatted status line — both provider/derived content.
    let title: String   // l10n:content — media title from the server
    let subtitle: Text
    let subtitleColor: Color
    let fraction: Double?
    let failure: String?
    let artworkURL: URL?
    let kind: MediaItemKind

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
        VStack(alignment: .leading, spacing: metrics.landscapeCaptionTopSpacing) {
            artwork
                .frame(maxWidth: .infinity)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .overlay { cornerScrim }
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: PlozzTheme.Metrics.mediumMediaCornerRadius,
                        style: .continuous
                    )
                )
                .plozzMediaEdge(
                    cornerRadius: PlozzTheme.Metrics.mediumMediaCornerRadius
                )
                .overlay(alignment: .bottom) { progressOverlay }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .foregroundStyle(palette.primaryText)
                subtitle
                    .font(.caption)
                    .foregroundStyle(subtitleColor)
                    .lineLimit(1)
                if let failure {
                    Text(failure)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, metrics.landscapeCaptionInset)
            .padding(
                .bottom,
                cardStyle == .framed ? metrics.landscapeCaptionInset : 0
            )
        }
        .contentShape(Rectangle())
    }

    private var artwork: some View {
        DownloadLocalArtwork(url: artworkURL) {
            ZStack {
                Color.secondary.opacity(0.12)
                Image(systemName: fallbackSymbol)
                    .font(.largeTitle)
                    .plozzForeground(.secondary)
            }
        }
    }

    /// A corner-anchored legibility scrim: dark at the top-leading corner (behind
    /// the "⋯" menu) fading to clear by roughly the middle of the artwork —
    /// similar to the detail episode card's gradient, but only where the menu sits
    /// so most of the image stays untouched.
    private var cornerScrim: some View {
        GeometryReader { proxy in
            RadialGradient(
                colors: [.black.opacity(0.5), .clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: max(proxy.size.width, proxy.size.height) * 0.55
            )
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var progressOverlay: some View {
        if let fraction {
            ProgressView(value: fraction)
                .tint(palette.accent)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .background(
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.55)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
    }

    private var fallbackSymbol: String {
        switch kind {
        case .episode, .series, .season:
            return "tv"
        case .movie, .video:
            return "film"
        case .collection, .folder, .unknown:
            return "photo"
        }
    }
}

struct PlozziOSDownloadSettingsView: View {
    @Bindable var model: PlozziOSDownloadsModel
    @State private var pendingBulkDeletion: PlozziOSDownloadsBulkDeletion?

    var body: some View {
        List {
            SettingsSectionGroup("Network") {
                Toggle("Allow Cellular Downloads", isOn: $model.allowsCellular)
                Toggle(
                    "Pause in Low Data Mode",
                    isOn: $model.pausesOnLowDataMode
                )
            } footer: {
                Text(
                    "These settings affect offline downloads only. Playback is never throttled."
                )
            }

            SettingsSectionGroup("Download Speed") {
                Picker(
                    "Limit",
                    selection: Binding(
                        get: {
                            let value = model.maximumDownloadMegabitsPerSecond
                            return [nil, 5, 10, 25, 50].contains(where: {
                                $0 == value
                            }) ? value ?? 0 : -1
                        },
                        set: {
                            model.maximumDownloadMegabitsPerSecond =
                                $0 == 0 ? nil : ($0 == -1 ? 15 : $0)
                        }
                    )
                ) {
                    Text("Unlimited").tag(0)
                    Text("5 Mbps").tag(5)
                    Text("10 Mbps").tag(10)
                    Text("25 Mbps").tag(25)
                    Text("50 Mbps").tag(50)
                    Text("Custom").tag(-1)
                }
                if let limit = model.maximumDownloadMegabitsPerSecond,
                   ![5, 10, 25, 50].contains(limit) {
                    Stepper(
                        "\(limit) Mbps",
                        value: Binding(
                            get: { limit },
                            set: {
                                model.maximumDownloadMegabitsPerSecond = $0
                            }
                        ),
                        in: 1...1_000
                    )
                }
                if model.maximumDownloadMegabitsPerSecond != nil {
                    Picker(
                        "When Plozz Is in the Background",
                        selection: $model.cappedBackgroundBehavior
                    ) {
                        Text("Pause Downloads")
                            .tag(CappedDownloadBackgroundBehavior.pause)
                        Text("Continue at Full Speed")
                            .tag(
                                CappedDownloadBackgroundBehavior
                                    .continueAtFullSpeed
                            )
                    }
                }
            } footer: {
                if model.maximumDownloadMegabitsPerSecond == nil {
                    Text("Downloads use the full available connection speed.")
                } else {
                    Text(
                        "iOS cannot enforce a speed limit on background transfers. Choose whether capped downloads pause or continue uncapped while Plozz is in the background."
                    )
                }
            }

            SettingsSectionGroup("Download Quality") {
                Picker("Default Quality", selection: $model.downloadQuality) {
                    Text("Original").tag(DownloadQuality.original)
                    Text("1080p • 20 Mbps")
                        .tag(DownloadQuality.hd1080)
                    Text("720p • 4 Mbps")
                        .tag(DownloadQuality.hd720)
                    Text("480p • 1.5 Mbps")
                        .tag(DownloadQuality.sd480)
                    if case .constrained(let constraint) =
                        model.downloadQuality,
                       ![
                           DownloadQuality.hd1080,
                           .hd720,
                           .sd480
                       ].contains(model.downloadQuality) {
                        Text(
                            "Custom • \(constraint.maximumHeight)p"
                        )
                        .tag(model.downloadQuality)
                    }
                }
                Toggle(
                    "Ask Before Downloading",
                    isOn: $model.asksBeforeDownloading
                )
                Toggle(
                    "Include All Audio Tracks",
                    isOn: $model.includesAllAudioTracks
                )
                Toggle(
                    "Include Text Subtitles",
                    isOn: $model.includesTextSubtitleTracks
                )
                if case .constrained(let constraint) = model.downloadQuality {
                    Stepper(
                        "Maximum Resolution: \(constraint.maximumHeight)p",
                        value: qualityHeightBinding(constraint),
                        in: 144...2_160,
                        step: 120
                    )
                    Stepper(
                        "Video Bitrate: \(Double(constraint.maximumVideoBitrateBps) / 1_000_000, specifier: "%.1f") Mbps",
                        value: qualityBitrateBinding(constraint),
                        in: 500_000...100_000_000,
                        step: 500_000
                    )
                }
            } footer: {
                if model.downloadQuality == .original {
                    Text(
                        "Original downloads the server’s existing file without transcoding."
                    )
                } else {
                    Text(
                        "Reduced quality asks Plex, Jellyfin, or Emby to transcode a separate offline copy. Plex keeps one audio track; choose Original to keep every track. Preparation can take time and use significant server CPU. Network shares support Original only."
                    )
                }
            }

            SettingsSectionGroup("Notifications") {
                Toggle(
                    "Standalone Download Completed",
                    isOn: $model.notifiesOnStandaloneCompletion
                )
                Toggle(
                    "Batch Completed",
                    isOn: $model.notifiesOnBatchCompletion
                )
                Toggle(
                    "Download Failed",
                    isOn: $model.notifiesOnFailure
                )
            } footer: {
                Text(
                    "Batch notifications summarize a season or show instead of notifying for every episode."
                )
            }

            if model.hasActiveTransfers {
                SettingsSectionGroup("In Progress") {
                    Button("Pause All", systemImage: "pause.circle") {
                        Task { await model.pauseAllActive() }
                    }
                    Button("Resume All", systemImage: "play.circle") {
                        Task { await model.resumeAllPaused() }
                    }
                    Button(
                        "Cancel Active Downloads",
                        systemImage: "xmark.circle",
                        role: .destructive
                    ) {
                        pendingBulkDeletion = .cancelActive(model.activeTransfers)
                    }
                }
            }

            SettingsSectionGroup("Storage") {
                PlozziOSDownloadsStorageBar(downloadsBytes: model.library.totalBytes)
                LabeledContent("Downloaded titles") {
                    Text(model.records.filter { $0.status == .completed }.count.formatted())
                }
                if !model.library.isEmpty {
                    Button(
                        "Delete All Downloads",
                        systemImage: "trash",
                        role: .destructive
                    ) {
                        pendingBulkDeletion = .all(model.library)
                    }
                }
            }
        }
        .settingsPageSurface()
        .navigationTitle("Downloads")
        .confirmationDialog(
            pendingBulkDeletion.map { Text($0.title) } ?? Text(verbatim: ""),
            isPresented: Binding(
                get: { pendingBulkDeletion != nil },
                set: { if !$0 { pendingBulkDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let deletion = pendingBulkDeletion {
                Button(deletion.confirmLabel, role: .destructive) {
                    let reevaluate = deletion.reevaluatesActiveAtConfirm
                    let records = deletion.records
                    pendingBulkDeletion = nil
                    Task {
                        if reevaluate {
                            await model.cancelActiveTransfers()
                        } else {
                            await model.remove(records)
                        }
                    }
                }
                Button("Cancel", role: .cancel) { pendingBulkDeletion = nil }
            }
        } message: {
            if let deletion = pendingBulkDeletion {
                Text(deletion.message)
            }
        }
    }

    private func qualityHeightBinding(
        _ constraint: DownloadRenditionConstraint
    ) -> Binding<Int> {
        Binding(
            get: { constraint.maximumHeight },
            set: {
                model.downloadQuality = .constrained(
                    .init(
                        maximumHeight: $0,
                        maximumVideoBitrateBps:
                            currentConstraint.maximumVideoBitrateBps
                    )
                )
            }
        )
    }

    private func qualityBitrateBinding(
        _ constraint: DownloadRenditionConstraint
    ) -> Binding<Int> {
        Binding(
            get: { constraint.maximumVideoBitrateBps },
            set: {
                model.downloadQuality = .constrained(
                    .init(
                        maximumHeight: currentConstraint.maximumHeight,
                        maximumVideoBitrateBps: $0
                    )
                )
            }
        )
    }

    private var currentConstraint: DownloadRenditionConstraint {
        if case .constrained(let constraint) = model.downloadQuality {
            return constraint
        }
        return .init(
            maximumHeight: 720,
            maximumVideoBitrateBps: 4_000_000
        )
    }
}

struct DownloadArtwork: View {
    let url: URL?
    let kind: MediaItemKind

    var body: some View {
        DownloadLocalArtwork(url: url) {
            ZStack {
                Color.secondary.opacity(0.12)
                Image(systemName: fallbackSymbol)
                    .font(.title2)
                    .plozzForeground(.secondary)
            }
        }
        .frame(width: 104, height: 60)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityHidden(true)
    }

    private var fallbackSymbol: String {
        switch kind {
        case .episode, .series, .season:
            return "tv"
        case .movie, .video:
            return "film"
        case .collection, .folder, .unknown:
            return "photo"
        }
    }
}

/// Loads a pinned local artwork file off the main thread and caches the decoded,
/// display-ready image. A grid of download tiles re-renders on every download
/// progress publish; decoding synchronously in `body` each time caused main-thread
/// work per tile, so decoding is moved to a detached task and cached by file path.
struct DownloadLocalArtwork<Placeholder: View>: View {
    let url: URL?
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder()
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else {
            image = nil
            return
        }
        let key = url.path as NSString
        if let cached = DownloadArtworkCache.shared.object(forKey: key) {
            image = cached
            return
        }
        let decoded = await Task.detached(priority: .userInitiated) {
            UIImage(contentsOfFile: url.path)?.preparingForDisplay()
        }.value
        guard !Task.isCancelled else { return }
        if let decoded {
            DownloadArtworkCache.shared.setObject(decoded, forKey: key)
        }
        image = decoded
    }
}

/// Process-wide cache of decoded download artwork, keyed by file path, so the
/// same pinned image isn't re-read/re-decoded on every re-render.
enum DownloadArtworkCache {
    static let shared: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 240
        return cache
    }()
}

/// Describes a confirmed bulk removal (a whole show, a whole season, all active
/// transfers, or everything) routed through one confirmation dialog.
struct PlozziOSDownloadsBulkDeletion: Identifiable {
    let id: String
    let title: LocalizedStringResource
    let message: LocalizedStringResource
    let confirmLabel: LocalizedStringResource
    let records: [DownloadedMediaRecord]
    /// When true, the confirm handler should re-derive the currently-active
    /// transfers instead of trusting `records` — so a download that completes
    /// while the dialog is on screen is not deleted (honoring "completed kept").
    var reevaluatesActiveAtConfirm = false

    static func show(_ show: PlozziOSDownloadedShow) -> Self {
        Self(
            id: "show:\(show.id)",
            title: "Remove \(show.title)?",
            message: "This deletes all \(show.episodeCount) downloaded episodes.",
            confirmLabel: "Remove \(show.episodeCount) Episodes",
            records: show.records
        )
    }

    static func season(
        _ season: PlozziOSDownloadedSeason,
        showTitle: String
    ) -> Self {
        Self(
            id: "season:\(season.id)",
            title: "Remove \(showTitle) \(season.title)?",
            message: "This deletes all \(season.episodeCount) downloaded episodes in this season.",
            confirmLabel: "Remove \(season.episodeCount) Episodes",
            records: season.records
        )
    }

    static func all(_ library: PlozziOSDownloadLibrary) -> Self {
        let records = library.movies.map(\.record) + library.shows.flatMap(\.records)
        return Self(
            id: "all",
            title: "Remove All Downloads?",
            message: "This deletes every downloaded movie and episode for this profile.",
            confirmLabel: "Remove All",
            records: records
        )
    }

    static func cancelActive(_ records: [DownloadedMediaRecord]) -> Self {
        Self(
            id: "cancel-active",
            title: "Cancel Active Downloads?",
            message: "This stops and removes \(records.count) in-progress downloads. Completed downloads are kept.",
            confirmLabel: "Cancel \(records.count) Downloads",
            records: records,
            reevaluatesActiveAtConfirm: true
        )
    }
}
#endif
