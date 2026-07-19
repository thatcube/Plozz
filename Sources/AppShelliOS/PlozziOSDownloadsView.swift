#if os(iOS)
import MediaDownloads
import SwiftUI

struct PlozziOSDownloadsView: View {
    @Bindable var model: PlozziOSDownloadsModel

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
            } else {
                List(model.records) { record in
                    DownloadRow(record: record, model: model)
                }
            }
        }
        .navigationTitle("Downloads")
        .toolbar {
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

struct PlozziOSDownloadSettingsView: View {
    @Bindable var model: PlozziOSDownloadsModel

    var body: some View {
        Form {
            Section {
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

            Section("Storage") {
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
        .navigationTitle("Downloads")
    }
}

private struct DownloadRow: View {
    let record: DownloadedMediaRecord
    let model: PlozziOSDownloadsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.snapshot.title)
                        .font(.headline)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                }
                Spacer()
                actionMenu
            }
            if record.status == .downloading || record.status == .queued {
                ProgressView(value: record.fractionCompleted ?? 0)
            }
            if let failure = record.failureReason, record.status == .failed {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
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
#endif
