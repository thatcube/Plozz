#if os(iOS)
import CoreModels
import CoreUI
import MediaDownloads
import SwiftUI
import UIKit

struct PlozziOSDownloadsView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Bindable var model: PlozziOSDownloadsModel
    let appModel: PlozziOSAppModel
    let onShowSettings: () -> Void

    var body: some View {
        Group {
            if let error = model.initializationError {
                ContentUnavailableView(
                    "Downloads Unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
            } else if model.records.isEmpty {
                ContentUnavailableView(
                    "No Downloads",
                    systemImage: "arrow.down.circle",
                    description: Text(
                        "Download a movie or episode from its detail page to watch offline."
                    )
                )
            } else if horizontalSizeClass == .regular {
                regularWidthContent
            } else {
                List(model.records) { record in
                    DownloadRow(
                        record: record,
                        model: model,
                        appModel: appModel
                    )
                }
            }
        }
        .navigationTitle("Downloads")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                PlozziOSSettingsAvatarButton(action: onShowSettings)
            }
            if horizontalSizeClass != .regular {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Toggle("Allow Cellular Downloads", isOn: $model.allowsCellular)
                        Toggle(
                            "Pause in Low Data Mode",
                            isOn: $model.pausesOnLowDataMode
                        )
                    } label: {
                        Label("Download Settings", systemImage: "ellipsis.circle")
                    }
                }
            }
        }
    }

    private var regularWidthContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox("Download Settings") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(
                            "Allow Cellular Downloads",
                            isOn: $model.allowsCellular
                        )
                        Toggle(
                            "Pause in Low Data Mode",
                            isOn: $model.pausesOnLowDataMode
                        )
                    }
                    .padding(.top, 6)
                }

                LazyVStack(spacing: 12) {
                    ForEach(model.records) { record in
                        DownloadRow(
                            record: record,
                            model: model,
                            appModel: appModel
                        )
                            .padding(14)
                            .background(
                                .thinMaterial,
                                in: RoundedRectangle(cornerRadius: 16)
                            )
                    }
                }
            }
            .padding()
            .frame(maxWidth: 920)
            .frame(maxWidth: .infinity)
        }
    }
}

struct PlozziOSDownloadSettingsView: View {
    @Bindable var model: PlozziOSDownloadsModel

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
    }
}

private struct DownloadRow: View {
    let record: DownloadedMediaRecord
    let model: PlozziOSDownloadsModel
    let appModel: PlozziOSAppModel

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            if let item = model.detailItem(for: record),
               let provider = appModel.provider(for: item) {
                NavigationLink {
                    PlozziOSItemDetailView(
                        appModel: appModel,
                        provider: provider,
                        item: item,
                        seerService: appModel.seerService
                    )
                } label: {
                    rowContent
                }
                .buttonStyle(.plain)
            } else {
                rowContent
            }
            actionMenu
        }
        .padding(.vertical, 4)
    }

    private var rowContent: some View {
        HStack(alignment: .center, spacing: 14) {
            DownloadArtwork(
                url: model.artworkURL(for: record),
                kind: record.snapshot.kind
            )

            VStack(alignment: .leading, spacing: 8) {
                Text(record.snapshot.title)
                    .font(.headline)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                if record.status == .downloading || record.status == .queued {
                    ProgressView(value: record.fractionCompleted ?? 0)
                }
                if let failure = record.failureReason, record.status == .failed {
                    Text(failure)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
    }

    private var actionMenu: some View {
        Menu {
            switch record.status {
            case .downloading:
                Button("Pause", systemImage: "pause") {
                    Task { await model.pause(record) }
                }
            case .paused, .failed:
                Button("Resume", systemImage: "play") {
                    Task { await model.resume(record) }
                }
            case .queued, .completed:
                EmptyView()
            }
            Button("Remove", systemImage: "trash", role: .destructive) {
                Task { await model.remove(record) }
            }
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 44, height: 44)
        }
    }

    private var statusText: String {
        switch record.status {
        case .queued: "Queued"
        case .downloading: "\(Int((record.fractionCompleted ?? 0) * 100))%"
        case .paused: "Paused"
        case .completed: "Available offline"
        case .failed: "Failed"
        }
    }

    private var statusColor: Color {
        switch record.status {
        case .completed: .green
        case .failed: .red
        default: .secondary
        }
    }
}

private struct DownloadArtwork: View {
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
#endif
