#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// **Customize Home** — the single place that controls what appears on the Home
/// screen. Everything Home-only lives here (nothing else does):
///  - **Merge libraries on Home** switch (the big mode decision — a *switch*).
///  - **Global rows** — Continue Watching / Watchlist / Recently Added, each a
///    *checkmark* (pick which appear).
///  - **Hero** — its on/off *switch* and all its settings (moved in from
///    the old Home Display page, since the hero is Home-only).
///  - **Per-library rows** (only when merging is off) — a *checkmark* per library
///    row you want promoted onto Home (Recently Added, Recommended rows).
///
/// Control vocabulary (maintainer's rule): a **switch** is a big on/off (merge,
/// hero, whole feature); a **checkmark** is a granular sub-choice (which rows).
/// Whole-library on/off lives on the separate **Your Libraries** screen.
struct CustomizeHomeDetailView: View {
    /// Discovered libraries (with kind + owning account) — powers the per-library
    /// row checklists and the hero's Random-source picker.
    let discoveredLibraries: LoadState<[AggregatedLibrary]>
    /// The per-profile Home/visibility model (merge switch, global-row + per-library
    /// row selection, library visibility).
    let homeVisibility: HomeLibraryVisibilityModel
    /// Spoiler-protection settings, folded in as a section here — hiding unwatched
    /// art/titles/ratings is a browsing concern, so it lives with Home rather than
    /// as its own thin top-level row.
    let spoilers: SpoilerSettingsModel

    @Environment(HeroSettingsModel.self) private var hero

    var body: some View {
        SettingsSplitLayout(title: "Home", sections: sections)
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
        [layoutSection, homeRowsSection, heroSection]
            + SpoilerSectionsBuilder(spoilers: spoilers).sections
    }

    // MARK: - Layout (merge switch)

    private var layoutSection: SettingsSplitSection {
        SettingsSplitSection(id: "layout", header: "Layout", rows: [
            SettingsSplitRow(
                id: "merge-libraries",
                title: "Merge Libraries",
                description: "On: every library's content is combined into unified rows (Continue Watching, Recently Added, and one Libraries row). Off: pick which of each library's own rows appear on Home below — you still browse any library from its tile.",
            ) {
                Toggle(isOn: Binding(
                    get: { homeVisibility.mergeLibrariesOnHome },
                    set: { merge in
                        homeVisibility.setMergeLibrariesOnHome(merge)
                        // Turning merge OFF is a clear "I want per-library rows"
                        // signal. Seed every applicable row for every Home-visible
                        // library so the unmerged Home starts full (the user pares
                        // it back), instead of empty. No-op once they've customized.
                        if !merge {
                            homeVisibility.seedLibraryRowsIfNeeded(defaultLibraryRowSeeds)
                        }
                    }
                )) {
                    Text("Merge libraries on Home")
                }
                .toggleStyle(SettingsSwitchToggleStyle())
            }
        ])
    }

    // MARK: - Rows on Home (one entry, grouped detail)

    /// A SINGLE master row whose detail groups every Home row into bordered
    /// containers: the "Shared" cross-library rows first, then — when merging is
    /// off — one card per Home-visible library, each headed by its name + provider
    /// logo. This replaces the old scattered layout (a global "Rows on Home" row
    /// plus a separate one repeated for every library), which read as disjointed.
    private var homeRowsSection: SettingsSplitSection {
        SettingsSplitSection(id: "home-rows", header: "Rows", rows: [
            SettingsSplitRow(
                id: "home-rows-all",
                title: "Rows on Home",
                description: homeVisibility.mergeLibrariesOnHome
                    ? "Pick which of the combined rows appear on Home. Turn off Merge Libraries (under Layout) to also choose each library's own rows."
                    : "Pick which rows appear on Home — the shared rows at the top, then each library's own rows, grouped below.",
            ) {
                homeRowsDetail
            }
        ])
    }

    /// The grouped detail: a "Shared" card (global rows) followed by one bordered
    /// card per Home-visible library (unmerged only).
    @ViewBuilder private var homeRowsDetail: some View {
        VStack(alignment: .leading, spacing: 24) {
            HomeRowsGroupCard(
                title: "Shared",
                subtitle: "Combined across every library",
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

            if !homeVisibility.mergeLibrariesOnHome {
                let libraries = homeVisibleLibraries
                if libraries.isEmpty {
                    HomeRowsGroupCard(
                        title: "No libraries shown on Home",
                        systemIcon: "rectangle.on.rectangle.slash"
                    ) {
                        Text("Enable a library on Your Libraries, or turn Merge Libraries back on.")
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
                            providerKind: library.providerKind
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
                SettingsDetailGroup(title: "Sources") {
                    SettingsCheckList(
                        options: HeroSourceKind.allCases,
                        title: { $0.displayName },
                        isChecked: { hero.settings.sources.contains($0) },
                        onToggle: { toggleSource($0) }
                    )
                }

                SettingsDetailGroup(title: "Items") {
                    LabeledSettingRow("Items in rotation") {
                        SettingsStepper(
                            options: Array(HeroSettings.maxItemsRange),
                            selection: $hero.settings.maxItems,
                            title: { "\($0)" }
                        )
                    }
                }

                if hero.settings.isEnabled(.randomFromLibrary) {
                    SettingsDetailGroup(
                        title: "Random Libraries",
                        description: "Leave all selected to use every library on Home."
                    ) {
                        randomLibrariesContent
                    }
                }

                SettingsDetailGroup(title: "Auto-Advance") {
                    VStack(alignment: .leading, spacing: 24) {
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
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.22), value: hero.settings.isEnabled)
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

    private func toggleSource(_ source: HeroSourceKind) {
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
    /// Fallback header glyph when there's no provider logo (the Shared / empty cards).
    var systemIcon: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 16) {
                Group {
                    if let providerKind {
                        ProviderBrandMark(provider: providerKind, size: 56, showsBackground: false)
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
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }
}
#endif
