#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// Arranges the libraries shown in the custom navigation rail: reorder them, and
/// move one below the divider to drop it from the navigation entirely.
///
/// Uses the app-wide ``LiftableReorderList`` — the same control (and the same
/// muscle memory) as the metadata-provider priority list. Hiding a library here is
/// a **chrome** decision only: it stays fully browsable from Home and Search. To
/// turn a library off everywhere, use Settings ▸ Your Libraries.
struct NavigationLibrariesDetailView: View {
    let scope: ProfileLibrariesScope
    @Environment(NavigationStyleSettingsModel.self) private var navigation

    @State private var isReordering = false

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.sectionSpacing) {
            switch scope.discoveredLibraries {
            case .idle, .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
            case .empty:
                Text(Self.noLibraries)
                    .font(.callout)
                    .plozzForeground(.secondary)
            case .failed:
                Text(Self.unavailable)
                    .font(.callout)
                    .plozzForeground(.secondary)
            case let .loaded(all):
                content(for: all)
            }
        }
        .task { await scope.reloadLibraries() }
    }

    @ViewBuilder
    private func content(for all: [AggregatedLibrary]) -> some View {
        let visible = all.filter { scope.homeVisibility.isEnabled($0.key) }
        let available = NavigationRailPlan.availableKeys(visibleLibraries: visible)
        let titles = Self.rowsByKey(visible: visible)

        VStack(alignment: .leading, spacing: SettingsMetrics.sectionSpacing) {
            LiftableReorderList(
                sections: navigation.librarySections(available: available),
                disabledSectionTitle: Self.hiddenDivider,
                disabledPlaceholder: Self.hiddenPlaceholder,
                isLifting: $isReordering,
                row: { key in
                    titles[key] ?? LiftableReorderList.Row(title: Text(verbatim: key))
                },
                onChange: { navigation.applyLibrarySections($0, available: available) }
            )

            Text(Self.footnote)
                .font(.caption)
                .plozzForeground(.secondary)

            Button(role: .destructive) {
                navigation.resetLibraryLayout()
            } label: {
                Label {
                    Text(Self.resetTitle)
                } icon: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(SettingsFocusButtonStyle())
            .disabled(isReordering)
        }
    }

    /// One row descriptor per arrangeable key: the library's own name and content
    /// glyph, plus the server it came from so two same-named libraries on different
    /// servers are told apart.
    private static func rowsByKey(
        visible: [AggregatedLibrary]
    ) -> [String: LiftableReorderList<String>.Row] {
        var rows: [String: LiftableReorderList<String>.Row] = [
            NavigationLibraryLayout.allLibrariesKey: LiftableReorderList<String>.Row(
                title: Text(AllLibrariesBrowse.title),
                symbolName: "square.stack.3d.up.fill"
            )
        ]
        for aggregated in NavigationRailPlan.browsableLibraries(visible) {
            rows[aggregated.key] = LiftableReorderList<String>.Row(
                title: aggregated.library.displayName,
                symbolName: aggregated.library.navigationSymbolName,
                detail: Text(verbatim: aggregated.serverName)
            )
        }
        return rows
    }

    // MARK: - Copy

    private static let hiddenDivider = LocalizedStringResource(
        "navigationLibraries.hiddenDivider",
        defaultValue: "Hidden",
        comment: "Divider in the navigation-libraries list; libraries below it are not shown in the navigation."
    )
    private static let hiddenPlaceholder = LocalizedStringResource(
        "navigationLibraries.hiddenPlaceholder",
        defaultValue: "Move a library here to keep it out of the navigation.",
        comment: "Empty-state drop target under the Hidden divider."
    )
    private static let footnote = LocalizedStringResource(
        "navigationLibraries.footnote",
        defaultValue: "Hiding a library here only removes it from the navigation. It stays on Home and in Search. To turn a library off everywhere, use Your Libraries.",
        comment: "Explains that hiding a library from the navigation is not the same as turning it off."
    )
    private static let resetTitle = LocalizedStringResource(
        "navigationLibraries.reset",
        defaultValue: "Show Every Library",
        comment: "Button that restores the default navigation arrangement."
    )
    private static let noLibraries = LocalizedStringResource(
        "navigationLibraries.none",
        defaultValue: "No libraries yet. Add a server to see them here.",
        comment: "Shown when the household has no libraries to arrange."
    )
    private static let unavailable = LocalizedStringResource(
        "navigationLibraries.unavailable",
        defaultValue: "Couldn't reach your servers. Your arrangement is safe — try again in a moment.",
        comment: "Shown when library discovery failed while arranging the navigation."
    )
}
#endif
