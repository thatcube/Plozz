#if os(iOS)
import CoreModels
import MediaDownloads
import SwiftUI

/// The drill-in page for a single downloaded show: seasons as sections, each
/// with its own episode count, size, and a "Remove Season" action, plus a
/// toolbar action to remove the entire show. Reads the show live from the
/// model's grouped library so it updates as episodes are deleted, and pops
/// itself once the last episode is gone.
struct PlozziOSDownloadedShowView: View {
    let showID: String
    @Bindable var model: PlozziOSDownloadsModel
    let appModel: PlozziOSAppModel

    @Environment(\.dismiss) private var dismiss
    @State private var pendingBulkDeletion: PlozziOSDownloadsBulkDeletion?
    @State private var detailNav: PlozziOSDownloadDetailNav?

    var body: some View {
        let show = currentShow
        Group {
            if let show {
                List {
                    ForEach(show.seasons) { season in
                        seasonSection(season, show: show)
                    }
                }
                .listStyle(.insetGrouped)
                .navigationTitle(show.title)
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(item: $detailNav) { nav in
                    if let provider = appModel.provider(for: nav.item) {
                        PlozziOSItemDetailView(
                            appModel: appModel,
                            provider: provider,
                            item: nav.item,
                            seerService: appModel.seerService
                        )
                    } else {
                        ContentUnavailableView(
                            "Details Unavailable",
                            systemImage: "wifi.slash",
                            description: Text("Reconnect to view full details.")
                        )
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(role: .destructive) {
                            pendingBulkDeletion = .show(show)
                        } label: {
                            Label("Remove Show", systemImage: "trash")
                        }
                    }
                }
            } else {
                ContentUnavailableView(
                    "No Downloads",
                    systemImage: "arrow.down.circle"
                )
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
                    let records = deletion.records
                    pendingBulkDeletion = nil
                    Task { await model.remove(records) }
                }
                Button("Cancel", role: .cancel) { pendingBulkDeletion = nil }
            }
        } message: {
            if let deletion = pendingBulkDeletion {
                Text(deletion.message)
            }
        }
        .onChange(of: showStillExists) { _, exists in
            if !exists { dismiss() }
        }
    }

    private var currentShow: PlozziOSDownloadedShow? {
        model.library.shows.first { $0.id == showID }
    }

    private var showStillExists: Bool {
        model.library.shows.contains { $0.id == showID }
    }

    @ViewBuilder
    private func seasonSection(
        _ season: PlozziOSDownloadedSeason,
        show: PlozziOSDownloadedShow
    ) -> some View {
        Section {
            ForEach(season.records) { record in
                episodeRow(record)
            }
        } header: {
            HStack {
                Text(season.title)
                Spacer()
                Button(role: .destructive) {
                    pendingBulkDeletion = .season(season, showTitle: show.title)
                } label: {
                    Text("Remove")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)
            }
        } footer: {
            Text(
                DownloadFormatting.showSubtitle(
                    episodeCount: season.episodeCount,
                    seasonCount: 1,
                    bytes: season.totalBytes
                )
            )
        }
    }

    @ViewBuilder
    private func episodeRow(_ record: DownloadedMediaRecord) -> some View {
        Button {
            if let item = model.playbackItem(for: record)
                ?? model.detailItem(for: record) {
                detailNav = PlozziOSDownloadDetailNav(item: item)
            }
        } label: {
            HStack(spacing: 10) {
                DownloadRowContent(
                    title: DownloadFormatting.episodeLabel(for: record),
                    subtitle: DownloadFormatting.status(for: record),
                    subtitleColor: DownloadFormatting.statusColor(for: record),
                    fraction: DownloadFormatting.activeFraction(for: record),
                    failure: DownloadFormatting.failure(for: record),
                    artworkURL: model.artworkURL(for: record),
                    kind: record.snapshot.kind
                )
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button("Remove", systemImage: "trash", role: .destructive) {
                Task { await model.remove(record) }
            }
        }
    }
}

/// Identifiable wrapper so a downloaded episode's detail page can be pushed via
/// `navigationDestination(item:)` from the Downloads show page.
struct PlozziOSDownloadDetailNav: Identifiable, Hashable {
    let item: MediaItem
    var id: String { item.id }

    static func == (
        lhs: PlozziOSDownloadDetailNav,
        rhs: PlozziOSDownloadDetailNav
    ) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
#endif
