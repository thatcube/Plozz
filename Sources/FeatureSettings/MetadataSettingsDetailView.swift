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
enum MetadataProviderListLogic {
    /// The two sections the UI shows, derived from the sparse override + the build
    /// baseline so no source is ever hidden and a stale/foreign persisted token can't
    /// materialize a phantom row.
    struct Sections: Equatable {
        var enabled: [MetadataSource]
        var disabled: [MetadataSource]
    }

    /// Splits the known sources into enabled (above divider, priority order) and
    /// disabled (below), honoring the user's explicit lists first, then the baseline.
    static func sections(
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

    /// `order` with `source` moved by `delta` (clamped: out-of-range is a no-op).
    static func moved(_ source: MetadataSource, by delta: Int, in order: [MetadataSource]) -> [MetadataSource] {
        var order = order
        guard let index = order.firstIndex(of: source) else { return order }
        let target = index + delta
        guard order.indices.contains(target) else { return order }
        order.swapAt(index, target)
        return order
    }

    /// Moves `source` from the enabled section to the top of the disabled section.
    static func disabling(_ source: MetadataSource, in sections: Sections) -> Sections {
        guard sections.enabled.contains(source) else { return sections }
        var s = sections
        s.enabled.removeAll { $0 == source }
        s.disabled.insert(source, at: 0)
        return s
    }

    /// Moves `source` from the disabled section to the bottom of the enabled section.
    static func enabling(_ source: MetadataSource, in sections: Sections) -> Sections {
        guard sections.disabled.contains(source) else { return sections }
        var s = sections
        s.disabled.removeAll { $0 == source }
        s.enabled.append(source)
        return s
    }
}

/// The "Metadata" Settings page: provider enable/disable + ordering (over the
/// Info.plist baseline), required attribution, live diagnostics, and cache budgets.
/// A household-wide concern (like Servers/Seerr), so it lives under "This Apple TV".
struct MetadataSettingsDetailView: View {
    let deps: MetadataSettingsDependencies

    @State private var snapshot: MetadataEnrichmentDiagnosticsSnapshot?
    @State private var isRefreshing = false
    @State private var confirmClear = false

    private var providers: MetadataProviderSettingsModel { deps.providers }
    private var cacheBudget: CacheBudgetSettingsModel { deps.cacheBudget }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                SettingsPageHeader(
                    "Metadata",
                    subtitle: "Artwork and details for your libraries — shared across every profile on this Apple TV."
                )
                providersSection
                requiredAttributionNote
                tmdbKeySection
                diagnosticsSection
                cacheSection
            }
            .frame(maxWidth: PlozzTheme.Metrics.settingsContentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
            .padding(.vertical, 24)
        }
        .scrollClipDisabled()
        .task { await refreshDiagnostics() }
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

    private func isOverridden(_ source: MetadataSource) -> Bool {
        providers.settings.isExplicitlyEnabled(source) || providers.settings.isDisabled(source)
    }

    private var providersSection: some View {
        let split = sections
        return SettingsPanel(
            title: "Metadata Providers",
            subtitle: "Drag providers into the order you want. Sources above the divider fill artwork and details, top first; move a source below the divider to stop using it. Changes apply as your libraries refresh.",
            footer: providers.settings.isEmpty ? "Using the app's built-in defaults." : nil,
            contentPadding: .settingsPanelRowContent
        ) {
            VStack(spacing: 10) {
                ForEach(Array(split.enabled.enumerated()), id: \.element) { index, source in
                    ProviderRow(
                        name: displayName(source),
                        isEnabled: true,
                        isOverridden: isOverridden(source),
                        rank: index + 1,
                        canMoveUp: index > 0,
                        canMoveDown: index < split.enabled.count - 1,
                        onToggleEnabled: { setEnabled(false, for: source) },
                        onMoveUp: { moveEnabled(source, by: -1) },
                        onMoveDown: { moveEnabled(source, by: 1) }
                    )
                }

                MetadataDisabledDivider()

                if split.disabled.isEmpty {
                    MetadataDisabledPlaceholder()
                } else {
                    ForEach(Array(split.disabled.enumerated()), id: \.element) { index, source in
                        ProviderRow(
                            name: displayName(source),
                            isEnabled: false,
                            isOverridden: isOverridden(source),
                            rank: nil,
                            canMoveUp: index > 0,
                            canMoveDown: index < split.disabled.count - 1,
                            onToggleEnabled: { setEnabled(true, for: source) },
                            onMoveUp: { moveDisabled(source, by: -1) },
                            onMoveDown: { moveDisabled(source, by: 1) }
                        )
                    }
                }

                if !providers.settings.isEmpty {
                    Button(role: .destructive) {
                        providers.resetToBuildDefaults()
                    } label: {
                        Label("Reset to Built-in Defaults", systemImage: "arrow.uturn.backward")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SettingsFocusButtonStyle())
                    .padding(.top, 4)
                }
            }
        }
    }

    private func persist(_ next: MetadataProviderListLogic.Sections) {
        providers.settings.setLists(enabled: next.enabled, disabled: next.disabled)
    }

    private func setEnabled(_ enabled: Bool, for source: MetadataSource) {
        let current = sections
        persist(enabled
            ? MetadataProviderListLogic.enabling(source, in: current)
            : MetadataProviderListLogic.disabling(source, in: current))
    }

    private func moveEnabled(_ source: MetadataSource, by delta: Int) {
        var next = sections
        next.enabled = MetadataProviderListLogic.moved(source, by: delta, in: next.enabled)
        persist(next)
    }

    private func moveDisabled(_ source: MetadataSource, by delta: Int) {
        var next = sections
        next.disabled = MetadataProviderListLogic.moved(source, by: delta, in: next.disabled)
        persist(next)
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
            subtitle: "Optional. Add a TMDB API Read Access Token (v4) to fetch TMDB artwork and details under your own TMDB account.",
            footer: nil,
            contentPadding: .settingsPanelRowContent
        ) {
            VStack(alignment: .leading, spacing: 14) {
                if tmdbKey.isConfigured {
                    Label("A TMDB key is saved on this Apple TV.", systemImage: "checkmark.seal")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
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

                Text(Self.tmdbKeyDisclosure)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
                .font(.callout).foregroundStyle(.secondary)
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

    /// Required disclosure: BYOK changes credential / attribution / rate-limit
    /// ownership only — never TMDB's licensing terms — and keeps the "not endorsed"
    /// notice with a link to TMDB's terms.
    private static let tmdbKeyDisclosure = """
    Using your own key changes only whose TMDB credentials, rate limit, and attribution \
    are used — it does not change TMDB's licensing terms or how you may use the artwork. \
    Your key is stored securely on this Apple TV and never leaves it. Plozz uses the TMDB \
    API but is not endorsed or certified by TMDB. See TMDB's Terms of Use at \
    themoviedb.org/terms-of-use and get a token at themoviedb.org/settings/api.
    """


    // MARK: - Attribution

    /// A compact required-attribution line under the providers list. TheTVDB and TMDB
    /// require visible credit whenever their APIs are used; the full per-service credits
    /// live on the dedicated Settings → Attributions & Licensing page, so this only
    /// surfaces the required notice and points there rather than duplicating the section.
    private var requiredAttributionNote: some View {
        let required = MetadataSourceAttribution.all
            .filter(\.isRequired)
            .map(\.name)
            .joined(separator: " and ")
        return Text("\(required) require visible credit when their data is used. Full credits are in Settings → Attributions & Licensing.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, -12)
    }

    // MARK: - Diagnostics

    private var diagnosticsSection: some View {
        SettingsPanel(
            title: "Diagnostics",
            subtitle: "A point-in-time snapshot — values are gathered live and may differ by a moment."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(lastUpdatedText).font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        Task { await refreshDiagnostics() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(SettingsFocusButtonStyle())
                    .disabled(isRefreshing)
                }

                if let snapshot {
                    diagnosticsRows(snapshot)
                } else {
                    Text("Loading…").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func diagnosticsRows(_ snapshot: MetadataEnrichmentDiagnosticsSnapshot) -> some View {
        infoRow("Artwork cache", byteText(snapshot.artworkCacheBytes))
        infoRow("Resolved-URL cache", byteText(snapshot.metadataCacheBytes))
        if let count = snapshot.resultCacheEntryCount {
            infoRow("In-memory results", "\(count)")
        }
        infoRow("Background work", workText(snapshot.work))

        if !snapshot.metadataCountPerSource.isEmpty {
            Divider()
            Text("Stored fields by source").font(.subheadline.weight(.semibold))
            ForEach(sortedCounts(snapshot.metadataCountPerSource), id: \.0) { source, count in
                infoRow(displayName(source), "\(count)")
            }
        }

        let tripped = snapshot.providerBreakers.filter(\.isTripped)
        Divider()
        if tripped.isEmpty {
            infoRow("Provider health", "All sources healthy")
        } else {
            Text("Unavailable sources").font(.subheadline.weight(.semibold))
            ForEach(tripped) { breaker in
                infoRow(displayName(breaker.source), (breaker.trippedReason ?? "unavailable").capitalized)
            }
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.callout).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.callout.weight(.medium)).multilineTextAlignment(.trailing)
        }
    }

    private var lastUpdatedText: String {
        guard let snapshot else { return "Not yet loaded" }
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        formatter.dateStyle = .none
        return "Updated \(formatter.string(from: snapshot.capturedAt))"
    }

    private func refreshDiagnostics() async {
        isRefreshing = true
        snapshot = await deps.diagnosticsSnapshot()
        isRefreshing = false
    }

    // MARK: - Cache

    private static let artworkBudgetOptions = [16, 32, 64, 128, 256]   // MiB
    private static let metadataBudgetOptions = [4, 8, 16, 32, 64]      // MiB

    private var cacheSection: some View {
        SettingsPanel(
            title: "Cache",
            subtitle: "Limit how much space cached artwork and lookups may use. Lowering a limit frees space immediately.",
            contentPadding: .settingsPanelRowContent
        ) {
            VStack(spacing: 16) {
                budgetRow(
                    title: "Artwork cache",
                    options: Self.artworkBudgetOptions,
                    selection: artworkBudgetBinding
                )
                budgetRow(
                    title: "Lookup cache",
                    options: Self.metadataBudgetOptions,
                    selection: metadataBudgetBinding
                )
                Button(role: .destructive) {
                    confirmClear = true
                } label: {
                    Label("Clear Cache Now", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SettingsFocusButtonStyle())
                .padding(.top, 4)
            }
        }
        .confirmationDialog("Clear cached metadata and artwork?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear Cache", role: .destructive) {
                Task {
                    await deps.clearCaches()
                    await refreshDiagnostics()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Cached images and resolved links are rebuilt automatically as you browse.")
        }
    }

    private func budgetRow(title: String, options: [Int], selection: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline.weight(.semibold))
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
        Task { await deps.applyCacheBudgets(settings) }
    }

    // MARK: - Helpers

    private func sortedCounts(_ counts: [MetadataSource: Int]) -> [(MetadataSource, Int)] {
        counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.rawValue < $1.key.rawValue }
            .map { ($0.key, $0.value) }
    }

    private func byteText(_ bytes: Int?) -> String {
        guard let bytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func workText(_ work: MetadataEnrichmentDiagnosticsSnapshot.WorkStatus) -> String {
        if work.isRunning { return "Running" }
        if work.queuedBacklogs > 0 || work.queuedItems > 0 {
            return "\(work.queuedItems + work.queuedBacklogs) queued"
        }
        return "Idle"
    }

    private func displayName(_ source: MetadataSource) -> String {
        MetadataSourceAttribution.for(source)?.name ?? source.rawValue.capitalized
    }
}

/// One provider row in the single ordered list: an always-visible reorder handle, an
/// enable/disable action, an override tag, and up/down reorder buttons. (Phase 1 is a
/// straightforward chevron+toggle bridge over the enabled+order model; the tvOS
/// lifted-row click-to-activate-move interaction replaces this in Phase 2.)
private struct ProviderRow: View {
    let name: String
    let isEnabled: Bool
    let isOverridden: Bool
    /// 1-based priority rank when enabled; `nil` when disabled.
    let rank: Int?
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onToggleEnabled: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal")
                .font(.headline)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            if let rank {
                Text("\(rank)")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 22)
            }

            Text(name)
                .font(.headline.weight(.semibold))
                .foregroundStyle(isEnabled ? .primary : .secondary)

            if isOverridden {
                Text("Custom")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor.opacity(0.20)))
            }

            Spacer()

            Button(action: onMoveUp) { Image(systemName: "chevron.up") }
                .buttonStyle(SettingsFocusButtonStyle())
                .disabled(!canMoveUp)
            Button(action: onMoveDown) { Image(systemName: "chevron.down") }
                .buttonStyle(SettingsFocusButtonStyle())
                .disabled(!canMoveDown)
            Button(action: onToggleEnabled) {
                Image(systemName: isEnabled ? "minus.circle" : "plus.circle")
            }
            .buttonStyle(SettingsFocusButtonStyle())
            .accessibilityLabel(isEnabled ? "Disable \(name)" : "Enable \(name)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }
}

/// The "Disabled" divider that separates enabled (above) from disabled (below).
private struct MetadataDisabledDivider: View {
    var body: some View {
        HStack(spacing: 12) {
            Text("Disabled")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Rectangle()
                .fill(Color.secondary.opacity(0.3))
                .frame(height: 1)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Disabled providers")
    }
}

/// Shown in the disabled area when nothing is disabled, so the disable target is
/// discoverable. (Phase 2 makes this a dashed, focusable drop target reachable by the
/// remote.)
private struct MetadataDisabledPlaceholder: View {
    var body: some View {
        Text("Move a provider here to stop using it.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                    .foregroundStyle(.secondary.opacity(0.5))
            )
    }
}
#endif
