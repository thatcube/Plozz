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

    @Environment(HeroSettingsModel.self) private var hero

    var body: some View {
        SettingsSplitLayout(title: "Customize Home", sections: sections)
    }

    private var sections: [SettingsSplitSection] {
        [layoutSection, homeRowsSection, heroSection]
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
                            homeVisibility.seedLibraryRowsIfEmpty(defaultLibraryRowSeeds)
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

    // MARK: - Hero (moved in from Home Display)

    private var heroSection: SettingsSplitSection {
        @Bindable var hero = hero
        var rows: [SettingsSplitRow] = [
            SettingsSplitRow(
                id: "hero-enabled",
                title: "Show on Home",
                description: "A cinematic, rotating spotlight at the top of Home, with a Continue Watching row tucked under its lower edge.",
            ) {
                Toggle("Show the hero", isOn: $hero.settings.isEnabled)
                    .toggleStyle(SettingsSwitchToggleStyle())
            }
        ]
        if hero.settings.isEnabled {
            rows.append(heroSourcesRow)
            rows.append(heroItemsRow)
            if hero.settings.isEnabled(.randomFromLibrary) {
                rows.append(randomLibrariesRow)
            }
            rows.append(heroAutoAdvanceRow)
            // Background Trailers is hidden until the feature ships. The setting
            // (`heroTrailersRow` / `trailersEnabled`) is intentionally kept so a
            // previously-saved choice survives and it can be re-listed later.
        }
        return SettingsSplitSection(id: "hero", header: "Hero", rows: rows)
    }

    private var heroSourcesRow: SettingsSplitRow {
        SettingsSplitRow(
            id: "hero-sources",
            title: "Sources",
            description: "Which content feeds the hero. Enabled sources are interleaved into one rotating set.",
            indented: true,
        ) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(HeroSourceKind.allCases) { source in
                    Toggle(isOn: sourceBinding(source)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Label(source.displayName, systemImage: source.symbolName)
                            Text(source.detail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(SettingsSwitchToggleStyle())
                }
            }
        }
    }

    private var heroItemsRow: SettingsSplitRow {
        @Bindable var hero = hero
        return SettingsSplitRow(
            id: "hero-items",
            title: "Items",
            description: "How many titles rotate through the hero.",
            indented: true,
        ) {
            LabeledSettingRow("Items in rotation") {
                SettingsStepper(
                    options: Array(HeroSettings.maxItemsRange),
                    selection: $hero.settings.maxItems,
                    title: { "\($0)" }
                )
            }
        }
    }

    private var heroAutoAdvanceRow: SettingsSplitRow {
        @Bindable var hero = hero
        return SettingsSplitRow(
            id: "hero-auto-advance",
            title: "Auto-Advance",
            description: "Automatically rotate to the next title after a few seconds. Rotation always pauses while the hero is focused.",
            indented: true,
        ) {
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

    private var heroTrailersRow: SettingsSplitRow {
        @Bindable var hero = hero
        return SettingsSplitRow(
            id: "hero-trailers",
            title: "Background Trailers",
            description: "Coming soon — play a muted trailer behind the hero when one is available. Fades in only once it's actually playing. Your choice is saved for when this lands.",
            indented: true,
        ) {
            Toggle("Play trailers in the background", isOn: $hero.settings.trailersEnabled)
                .toggleStyle(SettingsSwitchToggleStyle())
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

    private var randomLibrariesRow: SettingsSplitRow {
        let libraries = randomEligibleLibraries
        return SettingsSplitRow(
            id: "hero-random-libraries",
            title: "Random Libraries",
            description: "Which libraries the Random source draws from. Leave all selected to use every library shown on Home.",
            indented: true,
        ) {
            if libraries.isEmpty {
                Text("No movie or TV libraries are shown on this profile's Home yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(libraries) { library in
                        Toggle(isOn: randomLibraryBinding(for: library.key, universe: libraries)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(library.library.title)
                                Text(library.serverName)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(SettingsSwitchToggleStyle())
                    }
                }
            }
        }
    }

    private func sourceBinding(_ source: HeroSourceKind) -> Binding<Bool> {
        Binding(
            get: { hero.settings.sources.contains(source) },
            set: { isOn in
                let current = Set(hero.settings.sources)
                var next = current
                if isOn { next.insert(source) } else { next.remove(source) }
                hero.settings.sources = HeroSourceKind.allCases.filter { next.contains($0) }
            }
        )
    }

    private func randomLibraryBinding(for key: String, universe: [AggregatedLibrary]) -> Binding<Bool> {
        let allKeys = Set(universe.map(\.key))
        return Binding(
            get: {
                let keys = hero.settings.randomLibraryKeys
                return keys.isEmpty || keys.contains(key)
            },
            set: { isOn in
                var keys = hero.settings.randomLibraryKeys.isEmpty
                    ? allKeys
                    : hero.settings.randomLibraryKeys
                if isOn { keys.insert(key) } else { keys.remove(key) }
                keys.formIntersection(allKeys)
                hero.settings.randomLibraryKeys = (keys == allKeys) ? [] : keys
            }
        )
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
