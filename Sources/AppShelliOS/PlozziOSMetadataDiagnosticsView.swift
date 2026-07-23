#if os(iOS)
import CoreModels
import CoreUI
import FeatureSettings
import SwiftUI

/// Native iPhone/iPad metadata Diagnostics page — cache sizes, per-source stored
/// field counts, provider health, and cache budget controls. Styled like the
/// other `PlozziOS…` settings pages and driven by the shared diagnostics snapshot
/// + cache-budget closures from `MetadataSettingsDependencies`.
struct PlozziOSMetadataDiagnosticsView: View {
    let deps: MetadataSettingsDependencies

    @State private var snapshot: MetadataEnrichmentDiagnosticsSnapshot?
    @State private var isRefreshing = false
    @State private var confirmClear = false

    private var cacheBudget: CacheBudgetSettingsModel { deps.cacheBudget }

    private static let artworkBudgetOptions = [16, 32, 64, 128, 256]
    private static let metadataBudgetOptions = [4, 8, 16, 32, 64]

    var body: some View {
        Form {
            overviewSection
            storedFieldsSection
            cacheSection
        }
        .settingsPageSurface()
        .navigationTitle("Diagnostics")
        .task { await refresh() }
        .confirmationDialog(
            "Clear cached metadata and artwork?",
            isPresented: $confirmClear,
            titleVisibility: .visible
        ) {
            Button("Clear Cache", role: .destructive) {
                Task {
                    await deps.clearCaches()
                    await refresh()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Cached images and resolved links are rebuilt automatically as you browse.")
        }
    }

    // MARK: Overview

    @ViewBuilder
    private var overviewSection: some View {
        SettingsSectionGroup("Overview") {
            metricRow("Artwork cache", byteText(snapshot?.artworkCacheBytes))
            metricRow("URL cache", byteText(snapshot?.metadataCacheBytes))
            metricRow("Results", snapshot?.resultCacheEntryCount.map(String.init) ?? "—")
            metricRow("Work", snapshot.map { workText($0.work) } ?? "—")
            metricRow("Provider health", healthText)
            Button {
                Task { await refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(isRefreshing)
        } footer: {
            if let capturedAt = snapshot?.capturedAt {
                Text("Updated \(capturedAt, format: .dateTime.hour().minute().second())")
            } else {
                Text("Loading…")
            }
        }
    }

    // MARK: Stored fields + unavailable

    @ViewBuilder
    private var storedFieldsSection: some View {
        let counts = sortedCounts
        let unavailable = snapshot?.providerBreakers.filter(\.isTripped) ?? []
        SettingsSectionGroup("Stored Fields") {
            if counts.isEmpty {
                Text("None yet")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(counts, id: \.source) { item in
                    metricRow(displayName(item.source), item.count.formatted())
                }
            }
            if !unavailable.isEmpty {
                ForEach(unavailable) { breaker in
                    metricRow(
                        displayName(breaker.source),
                        (breaker.trippedReason ?? "Unavailable").capitalized,
                        valueColor: .orange
                    )
                }
            }
        } footer: {
            if !unavailable.isEmpty {
                Text("Unavailable sources are temporarily skipped and retried automatically.")
            }
        }
    }

    // MARK: Cache budgets

    @ViewBuilder
    private var cacheSection: some View {
        SettingsSectionGroup("Cache") {
            Stepper(value: artworkBudgetBinding, in: 1 ... Self.artworkBudgetOptions.count) {
                LabeledContent("Artwork limit", value: "\(currentArtworkMiB) MB")
            }
            Stepper(value: metadataBudgetBinding, in: 1 ... Self.metadataBudgetOptions.count) {
                LabeledContent("Lookups limit", value: "\(currentMetadataMiB) MB")
            }
            Button(role: .destructive) {
                confirmClear = true
            } label: {
                Label("Clear Cache", systemImage: "trash")
            }
        } footer: {
            Text("Budgets cap on-disk caches; lowering a budget evicts immediately.")
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func metricRow(_ title: String, _ value: String, valueColor: Color = .primary) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.callout.weight(.medium).monospacedDigit())
                .foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: Data

    private var sortedCounts: [(source: MetadataSource, count: Int)] {
        (snapshot?.metadataCountPerSource ?? [:])
            .sorted {
                $0.value != $1.value ? $0.value > $1.value : $0.key.rawValue < $1.key.rawValue
            }
            .map { (source: $0.key, count: $0.value) }
    }

    private var healthText: String {
        guard let snapshot else { return "—" }
        let count = snapshot.providerBreakers.lazy.filter(\.isTripped).count
        return count == 0 ? "All sources healthy" : "\(count) unavailable"
    }

    @MainActor
    private func refresh() async {
        isRefreshing = true
        snapshot = await deps.diagnosticsSnapshot()
        isRefreshing = false
    }

    private func byteText(_ bytes: Int?) -> String {
        guard let bytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func workText(_ work: MetadataEnrichmentDiagnosticsSnapshot.WorkStatus) -> String {
        if work.isRunning { return "Running" }
        let queued = work.queuedItems + work.queuedBacklogs
        return queued > 0 ? "\(queued) queued" : "Idle"
    }

    private func displayName(_ source: MetadataSource) -> String {
        MetadataSourceAttribution.for(source)?.name ?? source.rawValue.capitalized
    }

    // MARK: Cache budget bindings (index into the discrete option ladder)

    private var currentArtworkMiB: Int {
        cacheBudget.settings.artworkCacheBytes / (1024 * 1024)
    }

    private var currentMetadataMiB: Int {
        cacheBudget.settings.metadataCacheBytes / (1024 * 1024)
    }

    private var artworkBudgetBinding: Binding<Int> {
        stepBinding(
            options: Self.artworkBudgetOptions,
            currentMiB: currentArtworkMiB
        ) { miB in
            cacheBudget.settings.artworkCacheBytes = miB * 1024 * 1024
            applyBudgets()
        }
    }

    private var metadataBudgetBinding: Binding<Int> {
        stepBinding(
            options: Self.metadataBudgetOptions,
            currentMiB: currentMetadataMiB
        ) { miB in
            cacheBudget.settings.metadataCacheBytes = miB * 1024 * 1024
            applyBudgets()
        }
    }

    /// Maps a `Stepper`'s 1-based index over the discrete MB ladder to the stored
    /// byte budget, snapping the current value to the nearest option.
    private func stepBinding(
        options: [Int],
        currentMiB: Int,
        set: @escaping (Int) -> Void
    ) -> Binding<Int> {
        Binding(
            get: {
                let nearest = options.enumerated().min {
                    abs($0.element - currentMiB) < abs($1.element - currentMiB)
                }
                return (nearest?.offset ?? 0) + 1
            },
            set: { newIndex in
                let clamped = min(max(newIndex, 1), options.count)
                set(options[clamped - 1])
            }
        )
    }

    private func applyBudgets() {
        let settings = cacheBudget.settings
        Task { await deps.applyCacheBudgets(settings) }
    }
}
#endif
