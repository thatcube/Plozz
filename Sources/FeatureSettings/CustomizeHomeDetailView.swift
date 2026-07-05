#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// **Customize Home** — the single place that controls what appears on the Home
/// screen. Everything Home-only lives here (nothing else does):
///  - **Merge libraries on Home** switch (the big mode decision — a *switch*).
///  - **Global rows** — Continue Watching / Watchlist / Recently Added, each a
///    *checkmark* (pick which appear).
///  - **Featured Hero** — its on/off *switch* and all its settings (moved in from
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
        SettingsSplitLayout(sections: sections)
    }

    private var sections: [SettingsSplitSection] {
        var result: [SettingsSplitSection] = [
            layoutSection,
            globalRowsSection,
            heroSection
        ]
        if !homeVisibility.mergeLibrariesOnHome {
            result.append(contentsOf: perLibrarySections)
        }
        return result
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
                    set: { homeVisibility.setMergeLibrariesOnHome($0) }
                )) {
                    Text("Merge libraries on Home")
                }
                .toggleStyle(SettingsSwitchToggleStyle())
            }
        ])
    }

    // MARK: - Global rows (checkmarks)

    private var globalRowsSection: SettingsSplitSection {
        SettingsSplitSection(id: "global-rows", header: "Rows", rows: [
            SettingsSplitRow(
                id: "global-rows-list",
                title: "Rows on Home",
                description: "Which of the standard rows appear at the top of Home.",
            ) {
                SettingsCheckList(
                    options: HomeGlobalRow.allCases.map(GlobalRowOption.init),
                    title: { $0.row.title },
                    isChecked: { homeVisibility.isGlobalRowEnabled($0.row) },
                    onToggle: { opt in
                        homeVisibility.setGlobalRowEnabled(!homeVisibility.isGlobalRowEnabled(opt.row), for: opt.row)
                    }
                )
            }
        ])
    }

    private struct GlobalRowOption: Identifiable, Hashable {
        let row: HomeGlobalRow
        var id: String { row.rawValue }
    }

    // MARK: - Featured Hero (moved in from Home Display)

    private var heroSection: SettingsSplitSection {
        @Bindable var hero = hero
        var rows: [SettingsSplitRow] = [
            SettingsSplitRow(
                id: "hero-enabled",
                title: "Featured Hero",
                description: "A cinematic, rotating spotlight at the top of Home, with a Continue Watching row tucked under its lower edge.",
            ) {
                Toggle("Show the featured hero", isOn: $hero.settings.isEnabled)
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
            rows.append(heroTrailersRow)
        }
        return SettingsSplitSection(id: "hero", header: "Featured Hero", rows: rows)
    }

    private var heroSourcesRow: SettingsSplitRow {
        SettingsSplitRow(
            id: "hero-sources",
            title: "Sources",
            description: "Which content feeds the hero. Enabled sources are interleaved into one rotating set.",
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
        ) {
            Toggle("Play trailers in the background", isOn: $hero.settings.trailersEnabled)
                .toggleStyle(SettingsSwitchToggleStyle())
        }
    }

    // MARK: - Per-library rows (checkmarks; unmerged only)

    /// One section per Home-visible, non-music library, offering a checkmark for
    /// each row kind that library can contribute. Providers without a given row
    /// (e.g. Jellyfin has no discovery hubs) still list it; it simply yields
    /// nothing at render time — kept simple and predictable.
    private var perLibrarySections: [SettingsSplitSection] {
        let libraries = (discoveredLibraries.value ?? [])
            .filter { !$0.library.isMusic && homeVisibility.isVisibleOnHome($0.key) }
            .sorted { lhs, rhs in
                if lhs.serverName != rhs.serverName { return lhs.serverName < rhs.serverName }
                return lhs.library.title.localizedCaseInsensitiveCompare(rhs.library.title) == .orderedAscending
            }
        guard !libraries.isEmpty else {
            return [SettingsSplitSection(id: "per-library-empty", header: "Library Rows", rows: [
                SettingsSplitRow(
                    id: "per-library-none",
                    title: "No libraries shown on Home",
                    description: "Enable a library on Your Libraries, or turn Merge Libraries back on.",
                ) { EmptyView() }
            ])]
        }
        return libraries.map { library in
            SettingsSplitSection(id: "lib-\(library.key)", header: library.library.title, rows: [
                SettingsSplitRow(
                    id: "lib-rows-\(library.key)",
                    title: "Rows on Home",
                    description: "Which of \(library.library.title)'s rows appear on Home.",
                ) {
                    SettingsCheckList(
                        options: LibraryHomeRowKind.allCases.map { LibraryRowOption(libraryKey: library.key, kind: $0) },
                        title: { $0.kind.displayName },
                        isChecked: { homeVisibility.isLibraryRowEnabled($0.libraryKey, kind: $0.kind) },
                        onToggle: { opt in
                            let now = homeVisibility.isLibraryRowEnabled(opt.libraryKey, kind: opt.kind)
                            homeVisibility.setLibraryRowEnabled(!now, libraryKey: opt.libraryKey, kind: opt.kind)
                        }
                    )
                }
            ])
        }
    }

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
#endif
