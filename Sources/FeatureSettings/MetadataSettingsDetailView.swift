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
    public struct Sections: Equatable {
        public var enabled: [MetadataSource]
        public var disabled: [MetadataSource]

        public init(enabled: [MetadataSource], disabled: [MetadataSource]) {
            self.enabled = enabled
            self.disabled = disabled
        }
    }

    /// The flattened native-List representation used by iOS/iPadOS. The divider stays
    /// in the collection so dragging a provider across it changes enablement; the
    /// placeholder is appended after the divider when nothing is disabled yet, giving
    /// a visible drop target to drag a provider into.
    public enum ListItem: Hashable {
        case provider(MetadataSource)
        case divider
        case disabledPlaceholder
    }

    public static func listItems(for sections: Sections) -> [ListItem] {
        sections.enabled.map(ListItem.provider)
            + [.divider]
            + (sections.disabled.isEmpty
                ? [.disabledPlaceholder]
                : sections.disabled.map(ListItem.provider))
    }

    /// Applies native `List.onMove` offsets to the flattened list, then splits it back
    /// at the divider. The divider itself is immovable; providers dropped before it are
    /// enabled, providers dropped after it are disabled.
    public static func moving(
        fromOffsets offsets: IndexSet,
        toOffset destination: Int,
        in sections: Sections
    ) -> Sections {
        var items = listItems(for: sections)
        let movableOffsets = offsets
            .filter { items.indices.contains($0) && items[$0] != .divider && items[$0] != .disabledPlaceholder }
            .sorted()
        guard !movableOffsets.isEmpty else { return sections }

        let moving = movableOffsets.map { items[$0] }
        for index in movableOffsets.reversed() {
            items.remove(at: index)
        }
        let removedBeforeDestination = movableOffsets.filter { $0 < destination }.count
        let insertion = max(0, min(items.count, destination - removedBeforeDestination))
        items.insert(contentsOf: moving, at: insertion)

        guard let divider = items.firstIndex(of: .divider) else { return sections }
        let enabled = items[..<divider].compactMap(\.source)
        let disabled = items[items.index(after: divider)...].compactMap(\.source)
        return Sections(enabled: enabled, disabled: disabled)
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

    /// One step of the lifted-row move, treating the whole thing as a single ordered
    /// list with the divider between `enabled` (above) and `disabled` (below). Moving a
    /// source up raises its priority; crossing the divider upward re-enables it (at the
    /// bottom of enabled). Moving down lowers priority; crossing the divider downward
    /// disables it (at the top of disabled). At the very top/bottom it's a no-op.
    static func stepped(_ source: MetadataSource, up: Bool, in sections: Sections) -> Sections {
        var s = sections
        if let i = s.enabled.firstIndex(of: source) {
            if up {
                guard i > 0 else { return sections }          // already highest
                s.enabled.swapAt(i, i - 1)
            } else if i < s.enabled.count - 1 {
                s.enabled.swapAt(i, i + 1)
            } else {
                // Crossing the divider downward → disable at the top of disabled.
                s.enabled.remove(at: i)
                s.disabled.insert(source, at: 0)
            }
            return s
        }
        if let j = s.disabled.firstIndex(of: source) {
            if !up {
                guard j < s.disabled.count - 1 else { return sections }  // already lowest
                s.disabled.swapAt(j, j + 1)
            } else if j > 0 {
                s.disabled.swapAt(j, j - 1)
            } else {
                // Crossing the divider upward → re-enable at the bottom of enabled.
                s.disabled.remove(at: j)
                s.enabled.append(source)
            }
            return s
        }
        return sections
    }
}

private extension MetadataProviderListLogic.ListItem {
    var source: MetadataSource? {
        guard case let .provider(source) = self else { return nil }
        return source
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

    /// The source currently "lifted" for reordering (nil = none lifted).
    @State private var liftedSource: MetadataSource?
    @State private var isRestoringLiftedFocus = false
    @FocusState private var focusedSource: MetadataSource?
    @FocusState private var isDisabledPlaceholderFocused: Bool

    private var providers: MetadataProviderSettingsModel { deps.providers }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                SettingsPageHeader("Metadata")
                providersSection
                tmdbKeySection
                    .disabled(liftedSource != nil)
                diagnosticsLink
                    .disabled(liftedSource != nil)
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

    private func orderModeTitle(_ mode: MetadataProviderOrderMode) -> String {
        switch mode {
        case .recommended: "Recommended"
        case .custom: "Custom"
        }
    }

    #if os(tvOS)
    private var providersSection: some View {
        let split = sections
        return SettingsPanel(
            title: "Metadata Providers",
            contentPadding: .settingsPanelRowContent
        ) {
            VStack(alignment: .leading, spacing: 16) {
                SettingsSegmentedPicker(
                    options: MetadataProviderOrderMode.allCases,
                    selection: orderModeBinding,
                    title: orderModeTitle
                )

                Toggle("Prefer local artwork", isOn: preferLocalArtworkBinding)
                    .toggleStyle(SettingsSwitchToggleStyle())

                if providers.settings.orderMode == .custom {
                    VStack(spacing: 6) {
                        ForEach(Array(split.enabled.enumerated()), id: \.element) { index, source in
                            row(source, isEnabled: true, rank: index + 1)
                        }

                        MetadataDisabledDivider(isDropTarget: liftedSource != nil)

                        if split.disabled.isEmpty {
                            MetadataDisabledPlaceholder(isReordering: liftedSource != nil)
                                .focused($isDisabledPlaceholderFocused)
                                .onChange(of: isDisabledPlaceholderFocused) { _, isFocused in
                                    handleEmptyDisabledDropTargetFocus(isFocused)
                                }
                        } else {
                            ForEach(split.disabled, id: \.self) { source in
                                row(source, isEnabled: false, rank: nil)
                            }
                        }

                        Button(role: .destructive) {
                            liftedSource = nil
                            providers.resetToBuildDefaults()
                        } label: {
                            Label("Reset to Recommended", systemImage: "arrow.uturn.backward")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(SettingsFocusButtonStyle())
                        .disabled(liftedSource != nil)
                        .padding(.top, 6)
                    }
                    // Reorder rides the native focus move: while a row is lifted,
                    // moving focus to a neighbor becomes a one-step move.
                    .onChange(of: focusedSource) { _, newValue in
                        handleFocusMoveWhileLifted(to: newValue)
                    }
                }
            }
        }
    }

    private func row(_ source: MetadataSource, isEnabled: Bool, rank: Int?) -> some View {
        let lifting = liftedSource != nil
        return ProviderRow(
            name: displayName(source),
            isEnabled: isEnabled,
            isLifted: liftedSource == source,
            isDimmed: lifting && liftedSource != source,
            rank: rank,
            onPrimary: { toggleLift(source) }
        )
        .focused($focusedSource, equals: source)
    }

    /// Click handler: lift the focused row, or drop it if it's already lifted.
    private func toggleLift(_ source: MetadataSource) {
        withAnimation(.snappy(duration: 0.16)) {
            liftedSource = (liftedSource == source) ? nil : source
        }
    }

    /// When a row is lifted and focus moves to a different row (a d-pad press), reorder
    /// the lifted row one step toward that row. Focus is restored on the next layout
    /// pass: restoring it synchronously targets the row's old frame and can make a
    /// subsequent Down press appear to move upward.
    private func handleFocusMoveWhileLifted(to newValue: MetadataSource?) {
        guard !isRestoringLiftedFocus,
              let lifted = liftedSource,
              let target = newValue,
              target != lifted else { return }
        let combined = sections.enabled + sections.disabled
        guard let from = combined.firstIndex(of: lifted),
              let to = combined.firstIndex(of: target) else { return }
        let up = to < from
        let next = MetadataProviderListLogic.stepped(lifted, up: up, in: sections)
        guard next != sections else {
            restoreFocusAfterLayout(to: lifted)
            return
        }
        isRestoringLiftedFocus = true
        withAnimation(.easeOut(duration: 0.10)) {
            persist(next)
        }
        restoreFocusAfterLayout(to: lifted)
    }

    /// The dashed empty-disabled row is a real focus target. Landing on it while a
    /// provider is lifted means "move across the divider": disable the provider, then
    /// keep focus on that same provider in its new disabled position.
    private func handleEmptyDisabledDropTargetFocus(_ isFocused: Bool) {
        guard isFocused,
              !isRestoringLiftedFocus,
              let lifted = liftedSource else { return }
        let next = MetadataProviderListLogic.stepped(lifted, up: false, in: sections)
        guard next != sections else { return }
        isRestoringLiftedFocus = true
        withAnimation(.easeOut(duration: 0.10)) {
            persist(next)
        }
        restoreFocusAfterLayout(to: lifted)
    }

    /// Wait one run-loop turn for the reordered `ForEach` frames to settle before
    /// asking the focus engine to follow the lifted provider to its new slot.
    private func restoreFocusAfterLayout(to source: MetadataSource) {
        Task { @MainActor in
            await Task.yield()
            isDisabledPlaceholderFocused = false
            focusedSource = source
            isRestoringLiftedFocus = false
        }
    }
    #else
    /// iOS/iPadOS uses the native always-editing List reorder affordance over the same
    /// flattened model. The immovable divider separates enabled and disabled sources;
    /// dragging a provider across it changes enablement.
    private var providersSection: some View {
        let split = sections
        let items = MetadataProviderListLogic.listItems(for: split)
        return SettingsPanel(
            title: "Metadata Providers",
            contentPadding: .settingsPanelRowContent
        ) {
            VStack(alignment: .leading, spacing: 16) {
                SettingsSegmentedPicker(
                    options: MetadataProviderOrderMode.allCases,
                    selection: orderModeBinding,
                    title: orderModeTitle
                )

                Toggle("Prefer local artwork", isOn: preferLocalArtworkBinding)
                    .toggleStyle(SettingsSwitchToggleStyle())

                if providers.settings.orderMode == .custom {
                    List {
                        ForEach(items, id: \.self) { item in
                            iosProviderListRow(item, split: split)
                                .moveDisabled(item == .divider)
                        }
                        .onMove { offsets, destination in
                            persist(
                                MetadataProviderListLogic.moving(
                                    fromOffsets: offsets,
                                    toOffset: destination,
                                    in: sections
                                )
                            )
                        }
                    }
                    .listStyle(.plain)
                    .scrollDisabled(true)
                    .environment(\.editMode, .constant(.active))
                    .frame(height: CGFloat(items.count) * 54)
                }
            }
        }
    }

    @ViewBuilder
    private func iosProviderListRow(
        _ item: MetadataProviderListLogic.ListItem,
        split: MetadataProviderListLogic.Sections
    ) -> some View {
        switch item {
        case let .provider(source):
            HStack {
                if let index = split.enabled.firstIndex(of: source) {
                    Text(index + 1, format: .number)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(displayName(source))
                    .foregroundStyle(split.enabled.contains(source) ? .primary : .secondary)
            }
        case .divider:
            Text("Disabled")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
        case .disabledPlaceholder:
            Text("Drag a provider here to turn it off")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
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
                    Image(systemName: "chevron.right")
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
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Loading…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
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
                        title: "Artwork cache",
                        value: byteText(snapshot?.artworkCacheBytes)
                    )
                    MetadataDiagnosticMetric(
                        title: "URL cache",
                        value: byteText(snapshot?.metadataCacheBytes)
                    )
                    MetadataDiagnosticMetric(
                        title: "Results",
                        value: snapshot?.resultCacheEntryCount.map(String.init) ?? "—"
                    )
                    MetadataDiagnosticMetric(
                        title: "Work",
                        value: snapshot.map { workText($0.work) } ?? "—"
                    )
                }

                Divider()
                MetadataDiagnosticMetric(
                    title: "Provider health",
                    value: healthText
                )
            }
        }
    }

    private var healthText: String {
        guard let snapshot else { return "—" }
        let count = snapshot.providerBreakers.lazy.filter(\.isTripped).count
        return count == 0 ? "All sources healthy" : "\(count) unavailable"
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
}

private struct MetadataDiagnosticMetric: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
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
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                    ForEach(counts, id: \.source) { item in
                        MetadataDiagnosticMetric(
                            title: displayName(item.source),
                            value: item.count.formatted()
                        )
                    }
                }
            }

            if !unavailable.isEmpty {
                Divider()
                VStack(spacing: 10) {
                    Text("Unavailable")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(unavailable) { breaker in
                        MetadataDiagnosticMetric(
                            title: displayName(breaker.source),
                            value: (breaker.trippedReason ?? "Unavailable").capitalized
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
        title: String,
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

/// One focusable provider row in the single ordered list. The **whole row** is the
/// focus target (no per-row buttons). Click to "lift" it; while lifted, d-pad Up/Down
/// moves it (across the divider to enable/disable) as focus follows; click again to
/// drop. An always-visible reorder handle sits on the trailing edge.
private struct ProviderRow: View {
    let name: String
    let isEnabled: Bool
    let isLifted: Bool
    let isDimmed: Bool
    /// 1-based priority rank when enabled; `nil` when disabled.
    let rank: Int?
    let onPrimary: () -> Void

    var body: some View {
        Button(action: onPrimary) {
            HStack(spacing: 14) {
                if let rank {
                    Text("\(rank)")
                        .font(.callout.weight(.bold).monospacedDigit())
                        .frame(minWidth: 26, alignment: .trailing)
                }
                Text(name)
                    .font(.headline.weight(.semibold))
                Spacer(minLength: 12)
                Image(systemName: "line.3.horizontal")
                    .font(.title3)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(
            LiftableRowButtonStyle(
                isEnabled: isEnabled,
                isLifted: isLifted,
                suppressFocusAppearance: isDimmed
            )
        )
        .opacity(isDimmed ? 0.4 : 1)
        .scaleEffect(isLifted ? 1.04 : 1)
        .shadow(color: .black.opacity(isLifted ? 0.5 : 0), radius: isLifted ? 18 : 0, y: isLifted ? 9 : 0)
        .zIndex(isLifted ? 1 : 0)
    }
}

/// Row chrome using ONLY the existing Settings design language — no new colors. A
/// lifted (grabbed) or focused row both render as the standard tvOS inverted card
/// (white fill / black text in dark mode); "grabbed" is distinguished by the row's
/// scale + shadow and its dimmed neighbors (the tvOS Home-screen rearrange idiom),
/// not a tint. Foreground is set here so it always matches the fill.
private struct LiftableRowButtonStyle: ButtonStyle {
    let isEnabled: Bool
    let isLifted: Bool
    /// During reordering, native focus briefly visits the adjacent row to communicate
    /// direction. Hide that row's focus card so only the lifted row ever highlights.
    let suppressFocusAppearance: Bool
    @Environment(\.isFocused) private var isFocused
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        let inverted = isLifted || (isFocused && !suppressFocusAppearance)
        let invertedFill: Color = colorScheme == .dark ? .white : .black
        let invertedText: Color = colorScheme == .dark ? .black : .white

        let foreground: AnyShapeStyle = inverted
            ? AnyShapeStyle(invertedText)
            : (isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        let fill: AnyShapeStyle = inverted ? AnyShapeStyle(invertedFill) : AnyShapeStyle(Color.clear)

        return configuration.label
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .foregroundStyle(foreground)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(fill)
            )
    }
}

/// The "Disabled" divider that separates enabled (above) from disabled (below).
private struct MetadataDisabledDivider: View {
    let isDropTarget: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text("Disabled")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Rectangle()
                .fill(Color.secondary.opacity(isDropTarget ? 0.6 : 0.3))
                .frame(height: 1)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Disabled providers")
    }
}

/// Shown in the disabled area when nothing is disabled, so the disable target stays
/// discoverable: a lifted row moved down here becomes disabled.
private struct MetadataDisabledPlaceholder: View {
    let isReordering: Bool

    var body: some View {
        Button(action: {}) {
            Text("Move a provider here to stop using it.")
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 14)
                .padding(.horizontal, 16)
        }
        .buttonStyle(
            DisabledPlaceholderButtonStyle(
                suppressFocusAppearance: isReordering
            )
        )
    }
}

private struct DisabledPlaceholderButtonStyle: ButtonStyle {
    let suppressFocusAppearance: Bool
    @Environment(\.isFocused) private var isFocused
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        let showFocus = isFocused && !suppressFocusAppearance
        configuration.label
            .foregroundStyle(
                showFocus
                    ? (colorScheme == .dark ? Color.black : Color.white)
                    : Color.secondary
            )
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(
                        showFocus
                            ? (colorScheme == .dark ? Color.white : Color.black)
                            : Color.clear
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(
                        style: StrokeStyle(lineWidth: 1, dash: [6, 4])
                    )
                    .foregroundStyle(showFocus ? Color.clear : Color.secondary.opacity(0.5))
            )
    }
}
#endif
