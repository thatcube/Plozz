#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// Everything the metadata Settings surface needs, bundled so `SettingsView`'s init
/// grows by a single parameter. The two `@Observable` models are app-wide (created
/// once in `AppState`); the baseline order/roles describe the build's Info.plist
/// defaults so the UI can mark each provider "baseline" vs "override"; the closures
/// forward to the media-share runtime facet (diagnostics, cache-budget application,
/// clear). Kept in `CoreModels` terms so `FeatureSettings` needs no `MetadataKit`
/// dependency.
public struct MetadataSettingsDependencies {
    public var providers: MetadataProviderSettingsModel
    public var cacheBudget: CacheBudgetSettingsModel
    /// Step 9: the household TMDB bring-your-own-key model (opt-in, verify, remove).
    public var tmdbKey: TMDBUserKeyModel
    /// The build's baseline source order (Info.plist / code defaults) — seeds the
    /// single list and its default priority order.
    public var baselineOrder: [MetadataSource]
    /// The sources the build disables by default (below the divider at baseline) —
    /// used to show baseline-vs-override.
    public var baselineDisabled: Set<MetadataSource>
    public var diagnosticsSnapshot: @MainActor () async -> MetadataEnrichmentDiagnosticsSnapshot
    public var applyCacheBudgets: @MainActor (CacheBudgetSettings) async -> Void
    public var clearCaches: @MainActor () async -> Void

    public init(
        providers: MetadataProviderSettingsModel,
        cacheBudget: CacheBudgetSettingsModel,
        tmdbKey: TMDBUserKeyModel,
        baselineOrder: [MetadataSource],
        baselineDisabled: Set<MetadataSource>,
        diagnosticsSnapshot: @escaping @MainActor () async -> MetadataEnrichmentDiagnosticsSnapshot,
        applyCacheBudgets: @escaping @MainActor (CacheBudgetSettings) async -> Void,
        clearCaches: @escaping @MainActor () async -> Void
    ) {
        self.providers = providers
        self.cacheBudget = cacheBudget
        self.tmdbKey = tmdbKey
        self.baselineOrder = baselineOrder
        self.baselineDisabled = baselineDisabled
        self.diagnosticsSnapshot = diagnosticsSnapshot
        self.applyCacheBudgets = applyCacheBudgets
        self.clearCaches = clearCaches
    }
}

/// Pure ordering/enablement helpers for the metadata providers list, factored out of
/// the view so they're unit-testable without a running SwiftUI hierarchy. The user
/// model is a single ordered list split by a "Disabled" divider: ``enabled`` above (in
/// priority order), ``disabled`` below.
public enum MetadataProviderListLogic {
    /// The two sections the UI shows, derived from the sparse override + the build
    /// baseline so no source is ever hidden and a stale/foreign persisted token can't
    /// materialize a phantom row.
    ///
    /// The shape and every ordering operation are the app-wide
    /// ``OrderedVisibilityList`` model — this screen only supplies the metadata
    /// *policy* (how a sparse override resolves against the build baseline).
    public typealias Sections = OrderedVisibilityList.Sections<MetadataSource>

    /// The flattened native-List representation used by iOS/iPadOS. The divider stays
    /// in the collection so dragging a provider across it changes enablement; the
    /// placeholder is appended after the divider when nothing is disabled yet, giving
    /// a visible drop target to drag a provider into.
    public typealias ListItem = OrderedVisibilityList.ListItem<MetadataSource>

    public static func listItems(for sections: Sections) -> [ListItem] {
        OrderedVisibilityList.listItems(for: sections)
    }

    /// Applies native `List.onMove` offsets to the flattened list, then splits it back
    /// at the divider. The divider itself is immovable; providers dropped before it are
    /// enabled, providers dropped after it are disabled.
    public static func moving(
        fromOffsets offsets: IndexSet,
        toOffset destination: Int,
        in sections: Sections
    ) -> Sections {
        OrderedVisibilityList.moving(fromOffsets: offsets, toOffset: destination, in: sections)
    }

    /// Splits the known sources into enabled (above divider, priority order) and
    /// disabled (below), honoring the user's explicit lists first, then the baseline.
    public static func sections(
        settings: MetadataProviderSettings,
        baselineOrder: [MetadataSource],
        baselineDisabled: Set<MetadataSource>
    ) -> Sections {
        let known = Set(baselineOrder)
        let userEnabled = settings.enabledOrder.map { MetadataSource(rawValue: $0) }.filter { known.contains($0) }
        let userDisabled = settings.disabledOrder.map { MetadataSource(rawValue: $0) }.filter { known.contains($0) }
        let userEnabledSet = Set(userEnabled)
        let userDisabledSet = Set(userDisabled)

        func isDisabled(_ source: MetadataSource) -> Bool {
            if userDisabledSet.contains(source) { return true }
            if userEnabledSet.contains(source) { return false }
            return baselineDisabled.contains(source)
        }

        var seen: Set<MetadataSource> = []
        var enabled: [MetadataSource] = []
        for source in userEnabled where !isDisabled(source) && seen.insert(source).inserted {
            enabled.append(source)
        }
        for source in baselineOrder where !isDisabled(source) && seen.insert(source).inserted {
            enabled.append(source)
        }
        var disabled: [MetadataSource] = []
        for source in userDisabled where isDisabled(source) && seen.insert(source).inserted {
            disabled.append(source)
        }
        for source in baselineOrder where isDisabled(source) && seen.insert(source).inserted {
            disabled.append(source)
        }
        return Sections(enabled: enabled, disabled: disabled)
    }

    public static func settings(
        _ settings: MetadataProviderSettings,
        selecting mode: MetadataProviderOrderMode,
        baselineOrder: [MetadataSource],
        baselineDisabled: Set<MetadataSource>
    ) -> MetadataProviderSettings {
        var updated = settings
        if mode == .custom, updated.enabledOrder.isEmpty, updated.disabledOrder.isEmpty {
            updated.setLists(
                enabled: baselineOrder.filter { !baselineDisabled.contains($0) },
                disabled: baselineOrder.filter(baselineDisabled.contains)
            )
        }
        updated.orderMode = mode
        return updated
    }

    /// `order` with `source` moved by `delta` (clamped: out-of-range is a no-op).
    static func moved(_ source: MetadataSource, by delta: Int, in order: [MetadataSource]) -> [MetadataSource] {
        OrderedVisibilityList.moved(source, by: delta, in: order)
    }

    /// Moves `source` from the enabled section to the top of the disabled section.
    static func disabling(_ source: MetadataSource, in sections: Sections) -> Sections {
        OrderedVisibilityList.disabling(source, in: sections)
    }

    /// Moves `source` from the disabled section to the bottom of the enabled section.
    static func enabling(_ source: MetadataSource, in sections: Sections) -> Sections {
        OrderedVisibilityList.enabling(source, in: sections)
    }

    /// One step of the lifted-row move, treating the whole thing as a single ordered
    /// list with the divider between `enabled` (above) and `disabled` (below). Moving a
    /// source up raises its priority; crossing the divider upward re-enables it (at the
    /// bottom of enabled). Moving down lowers priority; crossing the divider downward
    /// disables it (at the top of disabled). At the very top/bottom it's a no-op.
    static func stepped(_ source: MetadataSource, up: Bool, in sections: Sections) -> Sections {
        OrderedVisibilityList.stepped(source, up: up, in: sections)
    }
}

/// The "Metadata" Settings page: provider enable/disable + ordering (over the
/// Info.plist baseline), TMDB credentials, and a focused diagnostics destination.
/// A household-wide concern (like Servers/Seerr), so it lives under "This Apple TV".
public struct MetadataSettingsDetailView: View {
    let deps: MetadataSettingsDependencies

    public init(deps: MetadataSettingsDependencies) {
        self.deps = deps
    }

    /// Whether a provider row is currently lifted for reordering. Owned by the
    /// shared ``LiftableReorderList`` and mirrored out so this page can disable its
    /// other controls while a reorder is in progress.
    @State private var isReordering = false

    private var providers: MetadataProviderSettingsModel { deps.providers }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                SettingsPageHeader("Metadata")
                providersSection
                tmdbKeySection
                    .disabled(isReordering)
                diagnosticsLink
                    .disabled(isReordering)
            }
            .frame(maxWidth: PlozzTheme.Metrics.settingsContentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
            .padding(.vertical, 24)
        }
        .scrollClipDisabled()
        #if os(iOS)
        // On tvOS the diagnostics `SettingsRoute` destination is registered by the
        // module's own `SettingsView`. AppShelliOS can't see the internal route, so
        // register it here for the stack this view is pushed onto.
        .navigationDestination(for: SettingsRoute.self) { route in
            if route == .metadataDiagnostics {
                MetadataDiagnosticsDetailView(deps: deps)
            }
        }
        #endif
    }

    // MARK: - Providers

    /// The single-list sections (enabled above the divider, disabled below) derived
    /// from the user override + the build baseline, so a provider is never hidden.
    private var sections: MetadataProviderListLogic.Sections {
        MetadataProviderListLogic.sections(
            settings: providers.settings,
            baselineOrder: deps.baselineOrder,
            baselineDisabled: deps.baselineDisabled
        )
    }

    private var orderModeBinding: Binding<MetadataProviderOrderMode> {
        Binding(
            get: { providers.settings.orderMode },
            set: { setOrderMode($0) }
        )
    }

    private var preferLocalArtworkBinding: Binding<Bool> {
        Binding(
            get: { !providers.settings.preferOnlineArtwork },
            set: { providers.settings.preferOnlineArtwork = !$0 }
        )
    }

    private func setOrderMode(_ mode: MetadataProviderOrderMode) {
        providers.settings = MetadataProviderListLogic.settings(
            providers.settings,
            selecting: mode,
            baselineOrder: deps.baselineOrder,
            baselineDisabled: deps.baselineDisabled
        )
    }

    private func orderModeTitle(_ mode: MetadataProviderOrderMode) -> LocalizedStringResource {
        switch mode {
        case .recommended:
            LocalizedStringResource(
                "metadataOrder.recommended",
                defaultValue: "Recommended",
                comment: "Metadata provider ordering option: use Plozz's recommended order."
            )
        case .custom:
            LocalizedStringResource(
                "metadataOrder.custom",
                defaultValue: "Custom",
                comment: "Metadata provider ordering option: use the user's own order."
            )
        }
    }

    /// The providers list: the app-wide reorder-and-hide control
    /// (``LiftableReorderList``) over the same flattened model on both platforms —
    /// lift-and-step with the d-pad on tvOS, native drag on iOS/iPadOS. Moving a
    /// provider across the "Disabled" divider is what turns it off.
    private var providersSection: some View {
        SettingsPanel(
            title: "Metadata Providers",
            contentPadding: .settingsPanelRowContent
        ) {
            VStack(alignment: .leading, spacing: 16) {
                SettingsSegmentedPicker(
                    options: MetadataProviderOrderMode.allCases,
                    selection: orderModeBinding,
                    title: orderModeTitle
                )

                Toggle("Prefer artwork from your library", isOn: preferLocalArtworkBinding)
                    .toggleStyle(SettingsSwitchToggleStyle())
                Text("Use artwork from your media server or files before online providers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if providers.settings.orderMode == .custom {
                    LiftableReorderList(
                        sections: sections,
                        disabledSectionTitle: Self.disabledSectionTitle,
                        disabledPlaceholder: Self.disabledPlaceholder,
                        isLifting: $isReordering,
                        row: { LiftableReorderList.Row(title: Text(displayName($0))) },
                        onChange: { persist($0) }
                    )

                    #if os(tvOS)
                    Button(role: .destructive) {
                        providers.resetToBuildDefaults()
                    } label: {
                        Label("Reset to Recommended", systemImage: "arrow.uturn.backward")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SettingsFocusButtonStyle())
                    .disabled(isReordering)
                    .padding(.top, 6)
                    #endif
                }
            }
        }
    }

    private static let disabledSectionTitle = LocalizedStringResource(
        "metadataProviders.disabledDivider",
        defaultValue: "Disabled",
        comment: "Divider in the metadata-providers list; providers below it are turned off."
    )

    #if os(tvOS)
    private static let disabledPlaceholder = LocalizedStringResource(
        "metadataProviders.disabledPlaceholder.tv",
        defaultValue: "Move a provider here to stop using it.",
        comment: "Empty-state drop target shown under the Disabled divider on Apple TV."
    )
    #else
    private static let disabledPlaceholder = LocalizedStringResource(
        "metadataProviders.disabledPlaceholder",
        defaultValue: "Drag a provider here to turn it off",
        comment: "Empty-state drop target shown under the Disabled divider on iPhone/iPad."
    )
    #endif


    private func persist(_ next: MetadataProviderListLogic.Sections) {
        providers.settings.setLists(enabled: next.enabled, disabled: next.disabled)
    }

    // MARK: - TMDB bring-your-own-key (Step 9)

    private var tmdbKey: TMDBUserKeyModel { deps.tmdbKey }

    /// A binding onto the model's obscured draft field.
    private var draftKeyBinding: Binding<String> {
        Binding(get: { tmdbKey.draftKey }, set: { tmdbKey.draftKey = $0 })
    }

    @ViewBuilder
    private var tmdbKeySection: some View {
        SettingsPanel(
            title: "Your Own TMDB Key",
            footer: nil,
            contentPadding: .settingsPanelRowContent
        ) {
            VStack(alignment: .leading, spacing: 14) {
                if tmdbKey.isConfigured {
                    Label("A TMDB key is saved on this Apple TV.", systemImage: "checkmark.seal")
                        .font(.callout.weight(.medium))
                        .plozzForeground(.secondary)
                }

                SecureField("TMDB v4 API Read Access Token", text: draftKeyBinding)
                    .textContentType(.password)
                    .disableAutocorrection(true)

                verifyStatusView

                if let storageError = tmdbKey.storageErrorMessage {
                    Label(storageError, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.weight(.medium)).foregroundStyle(.red)
                }

                HStack(spacing: 12) {
                    Button {
                        Task { await tmdbKey.saveDraft() }
                    } label: {
                        Label(tmdbKey.isConfigured ? "Replace Key" : "Save Key", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(SettingsFocusButtonStyle())
                    .disabled(!tmdbKey.canSaveDraft)

                    Button {
                        Task { await tmdbKey.verify() }
                    } label: {
                        Label("Verify Key", systemImage: "checkmark.shield")
                    }
                    .buttonStyle(SettingsFocusButtonStyle())
                    .disabled((!tmdbKey.canSaveDraft && !tmdbKey.isConfigured) || tmdbKey.verifyState == .verifying)

                    if tmdbKey.isConfigured {
                        Button(role: .destructive) {
                            Task { await tmdbKey.remove() }
                        } label: {
                            Label("Remove Key", systemImage: "trash")
                        }
                        .buttonStyle(SettingsFocusButtonStyle())
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var verifyStatusView: some View {
        switch tmdbKey.verifyState {
        case .idle:
            EmptyView()
        case .verifying:
            Label("Checking…", systemImage: "hourglass")
                .font(.callout).plozzForeground(.secondary)
        case .valid:
            Label("Key verified — TMDB authenticated successfully.", systemImage: "checkmark.circle.fill")
                .font(.callout.weight(.medium)).foregroundStyle(.green)
        case .invalid:
            Label("TMDB rejected this key. Check the token and try again.", systemImage: "xmark.octagon.fill")
                .font(.callout.weight(.medium)).foregroundStyle(.red)
        case .unreachable:
            Label("Couldn't reach TMDB to check the key. Try again in a moment.", systemImage: "wifi.exclamationmark")
                .font(.callout.weight(.medium)).foregroundStyle(.orange)
        }
    }

    // MARK: - Diagnostics

    private var diagnosticsLink: some View {
        SettingsPanel(contentPadding: .settingsPanelRowContent) {
            NavigationLink(value: SettingsRoute.metadataDiagnostics) {
                SettingsRowLabel(
                    icon: "chart.bar.xaxis",
                    title: "Diagnostics"
                ) {
                    Text("Cache and provider health")
                        .font(.subheadline)
                        .settingsRowSecondary()
                } trailing: {
                    Image(systemName: "chevron.forward")
                        .font(.caption.weight(.semibold))
                        .settingsRowSecondary()
                }
            }
            .buttonStyle(SettingsFocusButtonStyle())
        }
    }

    private func displayName(_ source: MetadataSource) -> String {
        MetadataSourceAttribution.for(source)?.name ?? source.rawValue.capitalized
    }
}

struct MetadataDiagnosticsDetailView: View {
    let deps: MetadataSettingsDependencies

    @State private var snapshot: MetadataEnrichmentDiagnosticsSnapshot?
    @State private var isRefreshing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SettingsPageHeader("Diagnostics")
                MetadataDiagnosticsOverviewPanel(
                    snapshot: snapshot,
                    isRefreshing: isRefreshing,
                    onRefresh: { Task { await refresh() } }
                )
                MetadataDiagnosticsSourcesPanel(
                    counts: sortedCounts,
                    unavailable: snapshot?.providerBreakers.filter(\.isTripped) ?? []
                )
                MetadataDiagnosticsCachePanel(
                    cacheBudget: deps.cacheBudget,
                    applyCacheBudgets: deps.applyCacheBudgets,
                    clearCaches: deps.clearCaches,
                    refreshDiagnostics: refresh
                )
            }
            .frame(maxWidth: PlozzTheme.Metrics.settingsContentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
            .padding(.vertical, 24)
        }
        .scrollClipDisabled()
        .task { await refresh() }
    }

    private var sortedCounts: [(source: MetadataSource, count: Int)] {
        (snapshot?.metadataCountPerSource ?? [:])
            .sorted {
                $0.value != $1.value
                    ? $0.value > $1.value
                    : $0.key.rawValue < $1.key.rawValue
            }
            .map { (source: $0.key, count: $0.value) }
    }

    @MainActor
    private func refresh() async {
        isRefreshing = true
        snapshot = await deps.diagnosticsSnapshot()
        isRefreshing = false
    }
}

private struct MetadataDiagnosticsOverviewPanel: View {
    let snapshot: MetadataEnrichmentDiagnosticsSnapshot?
    let isRefreshing: Bool
    let onRefresh: () -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 36),
        GridItem(.flexible(), spacing: 36),
    ]

    var body: some View {
        SettingsPanel(title: "Overview") {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    if let capturedAt = snapshot?.capturedAt {
                        Text("Updated \(capturedAt, format: .dateTime.hour().minute().second())")
                            .font(.footnote)
                            .plozzForeground(.secondary)
                    } else {
                        Text("Loading…")
                            .font(.footnote)
                            .plozzForeground(.secondary)
                    }
                    Spacer()
                    Button(action: onRefresh) {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(SettingsFocusButtonStyle())
                    .disabled(isRefreshing)
                }

                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    MetadataDiagnosticMetric(
                        title: Text("Artwork cache"),
                        value: Text(verbatim: byteText(snapshot?.artworkCacheBytes))
                    )
                    MetadataDiagnosticMetric(
                        title: Text("URL cache"),
                        value: Text(verbatim: byteText(snapshot?.metadataCacheBytes))
                    )
                    MetadataDiagnosticMetric(
                        title: Text("Results"),
                        value: Text(verbatim: snapshot?.resultCacheEntryCount.map { $0.formatted() } ?? "—")
                    )
                    MetadataDiagnosticMetric(
                        title: Text("Work"),
                        value: snapshot.map { Text(workText($0.work)) } ?? Text(verbatim: "—")
                    )
                }

                PlozzDivider()
                MetadataDiagnosticMetric(
                    title: Text("Provider health"),
                    value: healthText
                )
            }
        }
    }

    private var healthText: Text {
        guard let snapshot else { return Text(verbatim: "—") }
        let count = snapshot.providerBreakers.lazy.filter(\.isTripped).count
        return count == 0 ? Text("All sources healthy") : Text("\(count) unavailable")
    }

    private func byteText(_ bytes: Int?) -> String {
        guard let bytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func workText(_ work: MetadataEnrichmentDiagnosticsSnapshot.WorkStatus) -> LocalizedStringResource {
        if work.isRunning { return "Running" }
        let queued = work.queuedItems + work.queuedBacklogs
        return queued > 0 ? "\(queued) queued" : "Idle"
    }
}

/// Both halves are pre-built `Text` so a row can mix our copy with a measured
/// value without resolving either early — `String(localized:)` here would have
/// frozen the wording at the language in effect when the panel was built.
private struct MetadataDiagnosticMetric: View {
    let title: Text
    let value: Text

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            title
                .font(.callout)
                .plozzForeground(.secondary)
            Spacer(minLength: 12)
            value
                .font(.callout.weight(.medium).monospacedDigit())
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct MetadataDiagnosticsSourcesPanel: View {
    let counts: [(source: MetadataSource, count: Int)]
    let unavailable: [MetadataEnrichmentDiagnosticsSnapshot.ProviderBreakerState]

    private let columns = [
        GridItem(.flexible(), spacing: 36),
        GridItem(.flexible(), spacing: 36),
    ]

    var body: some View {
        FocusableSettingsPanel(title: "Stored Fields") {
            if counts.isEmpty {
                Text("None yet")
                    .font(.callout)
                    .plozzForeground(.secondary)
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                    ForEach(counts, id: \.source) { item in
                        MetadataDiagnosticMetric(
                            title: Text(verbatim: displayName(item.source)),
                            value: Text(verbatim: item.count.formatted())
                        )
                    }
                }
            }

            if !unavailable.isEmpty {
                PlozzDivider()
                VStack(spacing: 10) {
                    Text("Unavailable")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(unavailable) { breaker in
                        MetadataDiagnosticMetric(
                            title: Text(verbatim: displayName(breaker.source)),
                            value: breaker.trippedReason.map { Text(verbatim: $0.capitalized) }
                                ?? Text("Unavailable")
                        )
                    }
                }
            }
        }
    }

    private func displayName(_ source: MetadataSource) -> String {
        MetadataSourceAttribution.for(source)?.name ?? source.rawValue.capitalized
    }
}

private struct MetadataDiagnosticsCachePanel: View {
    let cacheBudget: CacheBudgetSettingsModel
    let applyCacheBudgets: @MainActor (CacheBudgetSettings) async -> Void
    let clearCaches: @MainActor () async -> Void
    let refreshDiagnostics: @MainActor () async -> Void

    @State private var confirmClear = false

    private static let artworkBudgetOptions = [16, 32, 64, 128, 256]
    private static let metadataBudgetOptions = [4, 8, 16, 32, 64]

    var body: some View {
        SettingsPanel(
            title: "Cache",
            contentPadding: .settingsPanelRowContent
        ) {
            VStack(spacing: 16) {
                HStack(alignment: .top, spacing: 28) {
                    budgetControl(
                        title: "Artwork",
                        options: Self.artworkBudgetOptions,
                        selection: artworkBudgetBinding
                    )
                    budgetControl(
                        title: "Lookups",
                        options: Self.metadataBudgetOptions,
                        selection: metadataBudgetBinding
                    )
                }

                Button(role: .destructive) {
                    confirmClear = true
                } label: {
                    Label("Clear Cache", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SettingsFocusButtonStyle())
            }
        }
        .confirmationDialog(
            "Clear cached metadata and artwork?",
            isPresented: $confirmClear,
            titleVisibility: .visible
        ) {
            Button("Clear Cache", role: .destructive) {
                Task {
                    await clearCaches()
                    await refreshDiagnostics()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Cached images and resolved links are rebuilt automatically as you browse.")
        }
    }

    private func budgetControl(
        title: LocalizedStringResource,
        options: [Int],
        selection: Binding<Int>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline.weight(.semibold))
            SettingsStepper(options: options, selection: selection) { "\($0) MB" }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var artworkBudgetBinding: Binding<Int> {
        Binding(
            get: { cacheBudget.settings.artworkCacheBytes / (1024 * 1024) },
            set: { newMiB in
                cacheBudget.settings.artworkCacheBytes = newMiB * 1024 * 1024
                applyBudgets()
            }
        )
    }

    private var metadataBudgetBinding: Binding<Int> {
        Binding(
            get: { cacheBudget.settings.metadataCacheBytes / (1024 * 1024) },
            set: { newMiB in
                cacheBudget.settings.metadataCacheBytes = newMiB * 1024 * 1024
                applyBudgets()
            }
        )
    }

    private func applyBudgets() {
        let settings = cacheBudget.settings
        Task { await applyCacheBudgets(settings) }
    }
}

#endif
