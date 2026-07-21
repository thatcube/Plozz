#if os(iOS)
import CoreModels
import CoreUI
import MediaDownloads
import SwiftUI
import UIKit

struct PlozziOSDownloadsView: View {
    @Environment(\.themePalette) private var palette
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
                PlozziOSSettingsAvatarButton(size: 30, action: onShowSettings)
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    PlozziOSDownloadSettingsView(model: model)
                } label: {
                    Label("Download Settings", systemImage: "gearshape")
                }
            }
        }
        .confirmationDialog(
            pendingBulkDeletion?.title ?? "",
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
        List {
            Section {
                PlozziOSDownloadsStorageBar(downloadsBytes: library.totalBytes)
                Button(
                    "Delete All Downloads",
                    systemImage: "trash",
                    role: .destructive
                ) {
                    pendingBulkDeletion = .all(library)
                }
            }
            .listRowBackground(palette.cardOpaqueSurface)
            .listRowSeparatorTint(palette.cardOpaqueBorder)

            Section {
                ForEach(library.entries) { entry in
                    switch entry {
                    case let .movie(movie):
                        movieRow(movie)
                    case let .show(show):
                        showRow(show)
                    }
                }
            }
            .listRowBackground(palette.cardOpaqueSurface)
            .listRowSeparatorTint(palette.cardOpaqueBorder)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func movieRow(_ movie: PlozziOSDownloadedMovie) -> some View {
        let record = movie.record
        DownloadRowLink(record: record, model: model, appModel: appModel) {
            DownloadRowContent(
                title: record.snapshot.title,
                subtitle: DownloadFormatting.status(for: record),
                subtitleColor: DownloadFormatting.statusColor(for: record),
                fraction: DownloadFormatting.activeFraction(for: record),
                failure: DownloadFormatting.failure(for: record),
                artworkURL: model.artworkURL(for: record),
                kind: record.snapshot.kind
            )
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button("Remove", systemImage: "trash", role: .destructive) {
                Task { await model.remove(record) }
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            transferSwipeActions(for: record)
        }
    }

    @ViewBuilder
    private func transferSwipeActions(
        for record: DownloadedMediaRecord
    ) -> some View {
        switch record.status {
        case .downloading, .queued:
            Button("Pause", systemImage: "pause") {
                Task { await model.pause(record) }
            }
            .tint(.orange)
        case .paused, .failed:
            Button("Resume", systemImage: "play") {
                Task { await model.resume(record) }
            }
            .tint(.blue)
        case .completed:
            EmptyView()
        }
    }

    @ViewBuilder
    private func showRow(_ show: PlozziOSDownloadedShow) -> some View {
        NavigationLink {
            PlozziOSDownloadedShowView(
                showID: show.id,
                model: model,
                appModel: appModel
            )
        } label: {
            DownloadRowContent(
                title: show.title,
                subtitle: DownloadFormatting.showSubtitle(
                    episodeCount: show.episodeCount,
                    seasonCount: show.seasons.count,
                    bytes: show.totalBytes
                ),
                subtitleColor: .secondary,
                fraction: nil,
                failure: nil,
                artworkURL: show.artworkRecord.flatMap(model.artworkURL(for:)),
                kind: .series
            )
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Remove", systemImage: "trash", role: .destructive) {
                pendingBulkDeletion = .show(show)
            }
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
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("\(DownloadFormatting.byteText(downloadsBytes)) used by downloads")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }

    private func segment(width: CGFloat, color: Color, minWidth: CGFloat = 0) -> some View {
        Rectangle()
            .fill(color)
            .frame(width: max(minWidth, width))
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
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
    static func status(for record: DownloadedMediaRecord) -> String {
        switch record.status {
        case .queued: "Queued"
        case .downloading:
            "\(Int((record.fractionCompleted ?? 0) * 100))%"
        case .paused: "Paused"
        case .completed:
            "Available offline • \(byteText(record.bytesDownloaded))"
        case .failed: "Failed"
        }
    }

    static func statusColor(for record: DownloadedMediaRecord) -> Color {
        switch record.status {
        case .completed: .green
        case .failed: .red
        default: .secondary
        }
    }

    static func activeFraction(for record: DownloadedMediaRecord) -> Double? {
        guard record.status == .downloading || record.status == .queued else {
            return nil
        }
        return record.fractionCompleted ?? 0
    }

    static func failure(for record: DownloadedMediaRecord) -> String? {
        record.status == .failed ? record.failureReason : nil
    }

    static func showSubtitle(
        episodeCount: Int,
        seasonCount: Int,
        bytes: Int64
    ) -> String {
        let episodes = "\(episodeCount) "
            + (episodeCount == 1 ? "episode" : "episodes")
        let seasons = seasonCount > 1 ? " • \(seasonCount) seasons" : ""
        return episodes + seasons + " • " + byteText(bytes)
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
    let title: String
    let subtitle: String
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
                Text(subtitle)
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

struct PlozziOSDownloadSettingsView: View {
    @Bindable var model: PlozziOSDownloadsModel
    @State private var pendingBulkDeletion: PlozziOSDownloadsBulkDeletion?

    var body: some View {
        Form {
            SettingsSectionGroup {
                Toggle("Allow Cellular Downloads", isOn: $model.allowsCellular)
                Toggle(
                    "Pause in Low Data Mode",
                    isOn: $model.pausesOnLowDataMode
                )
            } footer: {
                Text(
                    "Downloads use original quality. Network-share downloads continue while Plozz is open; Jellyfin, Emby, and Plex downloads can continue in the background."
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
                LabeledContent("Downloaded titles") {
                    Text(model.records.filter { $0.status == .completed }.count.formatted())
                }
                LabeledContent("Stored media") {
                    Text(
                        model.records
                            .filter { $0.status == .completed }
                            .reduce(Int64(0)) { $0 + $1.bytesDownloaded },
                        format: .byteCount(style: .file)
                    )
                }
            }
        }
        .settingsPageSurface()
        .navigationTitle("Downloads")
        .confirmationDialog(
            pendingBulkDeletion?.title ?? "",
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
}

struct DownloadArtwork: View {
    let url: URL?
    let kind: MediaItemKind

    var body: some View {
        Group {
            if let url, let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color.secondary.opacity(0.12)
                    Image(systemName: fallbackSymbol)
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
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

/// Describes a confirmed bulk removal (a whole show, a whole season, all active
/// transfers, or everything) routed through one confirmation dialog.
struct PlozziOSDownloadsBulkDeletion: Identifiable {
    let id: String
    let title: String
    let message: String
    let confirmLabel: String
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
