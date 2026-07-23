#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// **Home Page** — the single place that controls what appears on the Home
/// screen. Everything Home-only lives here (nothing else does):
///  - **Rows on Home** — one entry whose detail leads with the **Combine
///    libraries** *switch* (the big mode decision), then the row checklists: the
///    **Global rows** (Continue Watching / Watchlist / Recently Added) and, when
///    Combine is off, a **per-library rows** card per library (Recently Added,
///    Recommended). Combine lives with the rows because it only changes what those
///    row groups show.
///  - **Hero** — its on/off *switch* and all its settings (moved in from
///    the old Home Display page, since the hero is Home-only).
///
/// Control vocabulary (maintainer's rule): a **switch** is a big on/off (combine,
/// hero, whole feature); a **checkmark** is a granular sub-choice (which rows).
/// Whole-library on/off lives on the separate **Your Libraries** screen.
struct CustomizeHomeDetailView: View {
    /// Discovered libraries (with kind + owning account) — powers the per-library
    /// row checklists and the hero's Random-source picker.
    let discoveredLibraries: LoadState<[AggregatedLibrary]>
    /// The per-profile Home/visibility model (merge switch, global-row + per-library
    /// row selection, library visibility).
    let homeVisibility: HomeLibraryVisibilityModel
    /// Whether a Seerr server is configured. The hero's **Featured** source is
    /// sourced entirely from Seerr's trending feed, so without it that source has
    /// nothing to show — we keep the row visible (so it's discoverable) but
    /// disabled with a "Requires Seerr" note.
    let seerConfigured: Bool

    @Environment(HeroSettingsModel.self) private var hero
    @Environment(HeroBackgroundSettingsModel.self) private var heroBackground

    var body: some View {
        SettingsSplitLayout(title: "Customize Home", sections: sections)
            // If the user unmerged BEFORE library discovery finished, the initial
            // seed (in the toggle setter) was a no-op on an empty seed list. Retry
            // once libraries are known — on appear and when discovery loads — so the
            // unmerged Home fills in rather than staying empty until a re-toggle.
            // Idempotent: seeding runs only once (tracked by hasSeededLibraryRows).
            .onAppear { seedUnmergedRowsIfReady() }
            .onChange(of: discoveredLibraries.value?.count ?? 0) { _, _ in
                seedUnmergedRowsIfReady()
            }
    }

    /// Seeds the default per-library rows when unmerged and libraries are known.
    /// A no-op while merging, before discovery, or once seeding has already run.
    private func seedUnmergedRowsIfReady() {
        guard !homeVisibility.mergeLibrariesOnHome else { return }
        homeVisibility.seedLibraryRowsIfNeeded(defaultLibraryRowSeeds)
    }

    private var sections: [SettingsSplitSection] {
        [homeRowsSection, heroSection]
    }

    // MARK: - Rows on Home (one entry, grouped detail — leads with the Combine switch)

    /// A SINGLE master row whose detail leads with the **Combine libraries** switch
    /// (the row-composition mode) and then groups every Home row into bordered
    /// containers: the "Shared" cross-library rows first, then — when Combine is
    /// off — one card per Home-visible library, each headed by its name + provider
    /// logo. Combine lives here (not a separate section) because it only changes
    /// what these row groups show.
    private var homeRowsSection: SettingsSplitSection {
        SettingsSplitSection(id: "home-rows", header: "Rows", rows: [
            SettingsSplitRow(
                id: "home-rows-all",
                title: "Rows on Home",
            ) {
                homeRowsDetail
            }
        ])
    }

    /// The grouped detail: the always-available **Shared** rows card first, then
    /// the **Show each library's own rows** toggle, then (when that's on) one
    /// bordered card per Home-visible library. Reads top-to-bottom as base rows →
    /// optional per-library add-ons.
    @ViewBuilder private var homeRowsDetail: some View {
        VStack(alignment: .leading, spacing: 24) {
            HomeRowsGroupCard(
                title: "Shared rows",
                subtitle: "Combined across all your libraries",
                systemIcon: "rectangle.stack.fill"
            ) {
                SettingsCheckList(
                    options: HomeGlobalRow.allCases.map(GlobalRowOption.init),
                    title: { $0.row.title },
                    bordered: false,
                    isChecked: { homeVisibility.isGlobalRowEnabled($0.row) },
                    onToggle: { opt in
                        homeVisibility.setGlobalRowEnabled(!homeVisibility.isGlobalRowEnabled(opt.row), for: opt.row)
                    }
                )
            }

            // The per-library add-on. Framed as ADDITIVE ("show each library's own
            // rows") and bound to `!mergeLibrariesOnHome`, so turning it ON *adds*
            // the per-library cards below — the intuitive direction. The stored
            // flag stays `mergeLibrariesOnHome` (on == combined/shared-only).
            Toggle(isOn: Binding(
                get: { !homeVisibility.mergeLibrariesOnHome },
                set: { showPerLibrary in
                    homeVisibility.setMergeLibrariesOnHome(!showPerLibrary)
                    // Turning per-library rows ON is a clear "I want each library's
                    // own rows" signal. Seed every applicable row for every
                    // Home-visible library so it starts full (the user pares it
                    // back), instead of empty. No-op once customized.
                    if showPerLibrary {
                        homeVisibility.seedLibraryRowsIfNeeded(defaultLibraryRowSeeds)
                    }
                }
            )) {
                Text("Show each library's own rows")
            }
            .toggleStyle(SettingsSwitchToggleStyle())
            // Extra separation above the toggle so the always-on "Shared rows" card
            // reads as its own block, set apart from this optional add-on.
            .padding(.top, 16)

            if !homeVisibility.mergeLibrariesOnHome {
                let libraries = homeVisibleLibraries
                if libraries.isEmpty {
                    HomeRowsGroupCard(
                        title: "No libraries shown on Home",
                        systemIcon: "rectangle.on.rectangle.slash"
                    ) {
                        Text("Enable a library on Your Libraries to give it its own rows.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                    }
                } else {
                    ForEach(libraries) { library in
                        HomeRowsGroupCard(
                            title: library.library.title,
                            subtitle: library.serverName,
                            providerKind: library.providerKind,
                            transportKind: library.transportKind
                        ) {
                            SettingsCheckList(
                                options: rowKinds(for: library).map { LibraryRowOption(libraryKey: library.key, kind: $0) },
                                title: { $0.kind.displayName },
                                bordered: false,
                                isChecked: { homeVisibility.isLibraryRowEnabled($0.libraryKey, kind: $0.kind) },
                                onToggle: { opt in
                                    let now = homeVisibility.isLibraryRowEnabled(opt.libraryKey, kind: opt.kind)
                                    homeVisibility.setLibraryRowEnabled(!now, libraryKey: opt.libraryKey, kind: opt.kind)
                                }
                            )
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Home-visible, non-music libraries, sorted by server then title — the ones
    /// that get their own row-selection card in unmerged mode.
    private var homeVisibleLibraries: [AggregatedLibrary] {
        (discoveredLibraries.value ?? [])
            .filter { !$0.library.isMusic && homeVisibility.isVisibleOnHome($0.key) }
            .sorted { lhs, rhs in
                if lhs.serverName != rhs.serverName { return lhs.serverName < rhs.serverName }
                return lhs.library.title.localizedCaseInsensitiveCompare(rhs.library.title) == .orderedAscending
            }
    }

    /// The row kinds worth offering for a library. Discovery "hubs" are Plex-only
    /// (`libraryHubs` yields nothing for other providers), so a Jellyfin / media-
    /// share library never shows a dead "Recommended rows" checkmark.
    private func rowKinds(for library: AggregatedLibrary) -> [LibraryHomeRowKind] {
        LibraryHomeRowKind.allCases.filter { kind in
            switch kind {
            case .recentlyAdded: return true
            case .hubs: return library.providerKind == .plex
            }
        }
    }

    /// Every (library, applicable row) pair across the Home-visible libraries —
    /// the "everything on" set used to seed the unmerged Home the first time the
    /// user turns merging off. Mirrors exactly the checkmarks the per-library
    /// cards show, so seeding ticks all of them.
    private var defaultLibraryRowSeeds: [(libraryKey: String, kind: LibraryHomeRowKind)] {
        homeVisibleLibraries.flatMap { library in
            rowKinds(for: library).map { (libraryKey: library.key, kind: $0) }
        }
    }

    private struct GlobalRowOption: Identifiable, Hashable {
        let row: HomeGlobalRow
        var id: String { row.rawValue }
    }

    // MARK: - Hero (a single feature row: the whole hero form in one pane)

    /// One master row — "Hero" — whose detail pane holds the entire hero form:
    /// the on/off switch, then (revealed when on) Sources, Items, Random
    /// Libraries and Auto-Advance as headed groups. Previously these were five
    /// separate (mostly indented) master rows, which buried the feature; now Hero
    /// reads as one dedicated space.
    private var heroSection: SettingsSplitSection {
        SettingsSplitSection(id: "hero", header: nil, rows: [
            SettingsSplitRow(
                id: "hero",
                title: "Hero",
                description: "A cinematic, rotating spotlight at the top of Home, with a Continue Watching row tucked under its lower edge.",
            ) {
                heroForm
            }
        ])
    }

    @ViewBuilder private var heroForm: some View {
        @Bindable var hero = hero
        VStack(alignment: .leading, spacing: SettingsMetrics.sectionSpacing) {
            Toggle("Show the hero on Home", isOn: $hero.settings.isEnabled)
                .toggleStyle(SettingsSwitchToggleStyle())

            if hero.settings.isEnabled {
                Toggle(
                    "Hide watched movies, shows, and episodes",
                    isOn: $hero.settings.hideWatched
                )
                .toggleStyle(SettingsSwitchToggleStyle())

                SettingsDetailGroup(title: "Sources") {
                    SettingsCheckList(
                        options: orderedHeroSources,
                        title: { $0.displayName },
                        subtitle: { source in
                            (source == .featured && !seerConfigured) ? "Requires Seerr" : nil
                        },
                        isEnabled: { source in
                            source == .featured ? seerConfigured : true
                        },
                        isChecked: { source in
                            // Without Seerr, Featured can't be active — show it
                            // unchecked (and disabled) so it reads as unavailable,
                            // not "on". Stored preference is untouched, so it
                            // restores once Seerr is connected.
                            source == .featured && !seerConfigured
                                ? false
                                : hero.settings.sources.contains(source)
                        },
                        onToggle: { toggleSource($0) }
                    )
                }

                if hero.settings.isEnabled(.randomFromLibrary) {
                    SettingsDetailGroup(
                        title: "Random Libraries",
                        description: "Leave all selected to use every library on Home."
                    ) {
                        randomLibrariesContent
                    }
                }

                SettingsDetailGroup(title: "Rotation") {
                    VStack(alignment: .leading, spacing: 24) {
                        LabeledSettingRow("Items in rotation") {
                            SettingsStepper(
                                options: Array(HeroSettings.maxItemsRange),
                                selection: $hero.settings.maxItems,
                                title: { "\($0)" }
                            )
                        }
                        Toggle("Rotate automatically", isOn: $hero.settings.autoAdvance)
                            .toggleStyle(SettingsSwitchToggleStyle())
                        if hero.settings.autoAdvance {
                            LabeledSettingRow("Seconds per title") {
                                SettingsStepper(
                                    options: Array(HeroSettings.autoAdvanceRange),
                                    selection: $hero.settings.autoAdvanceSeconds,
                                    title: { "\($0)s" }
                                )
                            }
                        }
                    }
                }

                heroTrailerGroup
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.22), value: hero.settings.isEnabled)
    }

    @ViewBuilder private var heroTrailerGroup: some View {
        @Bindable var heroBackground = heroBackground
        SettingsDetailGroup(title: "Trailer") {
            VStack(alignment: .leading, spacing: 24) {
                Toggle(
                    "Play the trailer behind the hero",
                    isOn: $heroBackground.settings.homeTrailerEnabled
                )
                .toggleStyle(SettingsSwitchToggleStyle())
                if heroBackground.settings.homeTrailerEnabled {
                    Toggle(
                        "Start muted",
                        isOn: $heroBackground.settings.homeTrailerMuted
                    )
                    .toggleStyle(SettingsSwitchToggleStyle())
                }
            }
        }
    }

    // MARK: - Per-library row option identity

    private struct LibraryRowOption: Identifiable, Hashable {
        let libraryKey: String
        let kind: LibraryHomeRowKind
        var id: String { "\(libraryKey):\(kind.rawValue)" }
    }

    // MARK: - Hero helpers (unchanged from the old Home Display page)

    private var randomEligibleLibraries: [AggregatedLibrary] {
        (discoveredLibraries.value ?? [])
            .filter { $0.library.kind == .movie || $0.library.kind == .series }
            .filter { homeVisibility.isVisibleOnHome($0.key) }
            .sorted { lhs, rhs in
                if lhs.serverName != rhs.serverName { return lhs.serverName < rhs.serverName }
                return lhs.library.title.localizedCaseInsensitiveCompare(rhs.library.title) == .orderedAscending
            }
    }

    @ViewBuilder private var randomLibrariesContent: some View {
        let libraries = randomEligibleLibraries
        if libraries.isEmpty {
            Text("No movie or TV libraries are shown on this profile's Home yet.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            SettingsCheckList(
                options: libraries,
                title: { $0.library.title },
                subtitle: { $0.serverName },
                isChecked: { isRandomLibraryOn($0.key, universe: libraries) },
                onToggle: { toggleRandomLibrary($0.key, universe: libraries) }
            )
        }
    }

    /// Hero sources in the order shown in Settings: the always-available,
    /// library-sourced ones first, then **Featured** pinned last (it depends on
    /// Seerr, so it reads as the "extra" that may be disabled). The stored
    /// `sources` order is unaffected — `toggleSource` re-derives it from
    /// `allCases`, so curation/interleaving order doesn't change.
    private var orderedHeroSources: [HeroSourceKind] {
        HeroSourceKind.allCases.filter { $0 != .featured } + [.featured]
    }

    private func toggleSource(_ source: HeroSourceKind) {
        // Featured can't be enabled without Seerr (it has no content otherwise).
        guard source != .featured || seerConfigured else { return }
        var next = Set(hero.settings.sources)
        if next.contains(source) { next.remove(source) } else { next.insert(source) }
        hero.settings.sources = HeroSourceKind.allCases.filter { next.contains($0) }
    }

    /// A library feeds the Random source when it's explicitly selected, or when
    /// nothing is (empty == "all libraries").
    private func isRandomLibraryOn(_ key: String, universe: [AggregatedLibrary]) -> Bool {
        let keys = hero.settings.randomLibraryKeys
        return keys.isEmpty || keys.contains(key)
    }

    private func toggleRandomLibrary(_ key: String, universe: [AggregatedLibrary]) {
        let allKeys = Set(universe.map(\.key))
        var keys = hero.settings.randomLibraryKeys.isEmpty ? allKeys : hero.settings.randomLibraryKeys
        if keys.contains(key) { keys.remove(key) } else { keys.insert(key) }
        keys.formIntersection(allKeys)
        // Canonicalise "everything selected" back to empty.
        hero.settings.randomLibraryKeys = (keys == allKeys) ? [] : keys
    }
}

/// A titled, bordered container that groups one source's Home-row checkmarks in
/// the Customize Home detail pane — either the cross-library "Shared" rows (drawn
/// with an SF Symbol) or a single library, headed by its name + provider logo and
/// server. The border + small header make each source read as its own group
/// instead of a flat, repeating list.
private struct HomeRowsGroupCard<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    /// When set, the header shows this provider's brand logo (library cards).
    var providerKind: ProviderKind? = nil
    /// For a media-share library, the transport shown as a badge on its drive icon.
    var transportKind: MediaShareTransportKind? = nil
    /// Fallback header glyph when there's no provider logo (the Shared / empty cards).
    var systemIcon: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 16) {
                Group {
                    if let providerKind {
                        ProviderBrandMark(provider: providerKind, size: 56, showsBackground: false, mediaShareTransport: transportKind)
                    } else if let systemIcon {
                        Image(systemName: systemIcon)
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 56, height: 56)
                // Library title + server name on ONE line ("Movies · Brandoland"):
                // the title reads prominent, the server name trails as a lighter
                // qualifier separated by a mid-dot.
                HStack(spacing: 8) {
                    Text(title)
                        .font(.headline.weight(.semibold))
                    if let subtitle {
                        Text("·")
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 8)

            content()
                .padding(.horizontal, 22)
                .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: PlozzTheme.Metrics.Radius.card, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: PlozzTheme.Metrics.Radius.card, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }
}
#endif
