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
    /// The build's baseline source order (Info.plist / code defaults).
    public var baselineOrder: [MetadataSource]
    /// The build's baseline role per source (used to show baseline-vs-override).
    public var baselineRoles: [MetadataSource: MetadataProviderState]
    public var diagnosticsSnapshot: @MainActor () async -> MetadataEnrichmentDiagnosticsSnapshot
    public var applyCacheBudgets: @MainActor (CacheBudgetSettings) async -> Void
    public var clearCaches: @MainActor () async -> Void

    public init(
        providers: MetadataProviderSettingsModel,
        cacheBudget: CacheBudgetSettingsModel,
        tmdbKey: TMDBUserKeyModel,
        baselineOrder: [MetadataSource],
        baselineRoles: [MetadataSource: MetadataProviderState],
        diagnosticsSnapshot: @escaping @MainActor () async -> MetadataEnrichmentDiagnosticsSnapshot,
        applyCacheBudgets: @escaping @MainActor (CacheBudgetSettings) async -> Void,
        clearCaches: @escaping @MainActor () async -> Void
    ) {
        self.providers = providers
        self.cacheBudget = cacheBudget
        self.tmdbKey = tmdbKey
        self.baselineOrder = baselineOrder
        self.baselineRoles = baselineRoles
        self.diagnosticsSnapshot = diagnosticsSnapshot
        self.applyCacheBudgets = applyCacheBudgets
        self.clearCaches = clearCaches
    }
}

/// Pure ordering/role helpers for the metadata providers list, factored out of the
/// view so they're unit-testable without a running SwiftUI hierarchy.
enum MetadataProviderListLogic {
    /// The order to display sources in: the user's explicit order first (deduped and
    /// filtered to sources this build knows), then any baseline source the user
    /// hasn't placed, so none is ever hidden and a stale/foreign persisted token
    /// can't materialize as a phantom row.
    static func displayOrder(userOrder: [String], baselineOrder: [MetadataSource]) -> [MetadataSource] {
        let known = Set(baselineOrder)
        var seen: Set<MetadataSource> = []
        var result: [MetadataSource] = []
        for source in userOrder.map({ MetadataSource(rawValue: $0) })
        where known.contains(source) && seen.insert(source).inserted {
            result.append(source)
        }
        for source in baselineOrder where seen.insert(source).inserted {
            result.append(source)
        }
        return result
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
                tmdbKeySection
                attributionSection
                diagnosticsSection
                cacheSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
            .padding(.vertical, 24)
        }
        .scrollClipDisabled()
        .task { await refreshDiagnostics() }
    }

    // MARK: - Providers

    /// The order the UI shows sources in: the user's explicit order (if any) first,
    /// then any baseline source the user hasn't placed, so a provider is never hidden.
    private var displayOrder: [MetadataSource] {
        MetadataProviderListLogic.displayOrder(
            userOrder: providers.settings.order,
            baselineOrder: deps.baselineOrder
        )
    }

    private func baselineRole(_ source: MetadataSource) -> MetadataProviderState {
        deps.baselineRoles[source] ?? .primary
    }

    private func effectiveRole(_ source: MetadataSource) -> MetadataProviderState {
        providers.settings.role(for: source) ?? baselineRole(source)
    }

    private func isOverridden(_ source: MetadataSource) -> Bool {
        providers.settings.role(for: source) != nil
    }

    private var providersSection: some View {
        SettingsPanel(
            title: "Metadata Providers",
            subtitle: "Choose which sources fill artwork and details, and in what order. Changes apply as your libraries refresh.",
            footer: providers.settings.isEmpty ? "Using the app's built-in defaults." : nil,
            contentPadding: .settingsPanelRowContent
        ) {
            VStack(spacing: 10) {
                ForEach(Array(displayOrder.enumerated()), id: \.element) { index, source in
                    ProviderRow(
                        name: displayName(source),
                        role: effectiveRole(source),
                        isOverridden: isOverridden(source),
                        canMoveUp: index > 0,
                        canMoveDown: index < displayOrder.count - 1,
                        onSetRole: { setRole($0, for: source) },
                        onMoveUp: { move(source, by: -1) },
                        onMoveDown: { move(source, by: 1) }
                    )
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

    private func setRole(_ role: MetadataProviderState, for source: MetadataSource) {
        // Clearing an override that matches the baseline keeps the row reading
        // "baseline"; otherwise record the explicit user choice.
        providers.settings.setRole(role == baselineRole(source) ? nil : role, for: source)
    }

    private func move(_ source: MetadataSource, by delta: Int) {
        providers.settings.setOrder(
            MetadataProviderListLogic.moved(source, by: delta, in: displayOrder)
        )
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

    private var attributionSection: some View {
        SettingsPanel(
            title: "Attribution",
            subtitle: "Plozz is not affiliated with, endorsed, or certified by these services."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(MetadataSourceAttribution.all) { attribution in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(attribution.name).font(.headline.weight(.semibold))
                            if attribution.isRequired {
                                Text("Required")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(Capsule().fill(Color.primary.opacity(0.12)))
                            }
                        }
                        Text(attribution.notice)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
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

/// One provider row: a Primary / Secondary / Off stepper, an override tag, and
/// up/down reorder buttons.
private struct ProviderRow: View {
    let name: String
    let role: MetadataProviderState
    let isOverridden: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onSetRole: (MetadataProviderState) -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void

    private static let roleOptions: [MetadataProviderState] = [.disabled, .secondary, .primary]

    private var roleBinding: Binding<MetadataProviderState> {
        Binding(get: { role }, set: { onSetRole($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(name).font(.headline.weight(.semibold))
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
            }
            SettingsStepper(options: Self.roleOptions, selection: roleBinding) { label(for: $0) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    private func label(for state: MetadataProviderState) -> String {
        switch state {
        case .primary: return "Primary"
        case .secondary: return "Secondary"
        case .disabled: return "Off"
        }
    }
}
#endif
