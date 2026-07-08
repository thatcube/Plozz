#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// "Choose your libraries" — shown right after one or more servers are added
/// (both first run and later adds). It lists the just-added servers' libraries
/// as toggles, all **on** by default, so the user can turn off any library they
/// don't want before continuing. Each toggle is the library's **Enabled** switch
/// (the same on/off shown later in Settings › Your Libraries) — off hides the
/// library everywhere (Home, Search, Music, browse). Writes straight through to
/// `HomeLibraryVisibilityModel`.
///
/// Mirrors `PlexUserSelectionView`'s layout: a pinned header + footer with a
/// clipped scroll between them, and inner gutters so the focus fill/shadow
/// never gets clipped at the width restriction.
struct SelectLibrariesView: View {
    let appState: AppState

    @State private var discovery = LibraryDiscoveryModel()
    @FocusState private var focused: Field?

    private enum Field: Hashable {
        case library(String)
        case continueButton
    }

    /// The just-added accounts' libraries, grouped by server in discovery order.
    private struct ServerGroup: Identifiable {
        let id: String
        let serverName: String
        let providerKind: ProviderKind
        let libraries: [AggregatedLibrary]
    }

    private func groups(from libraries: [AggregatedLibrary]) -> [ServerGroup] {
        var order: [String] = []
        var byAccount: [String: [AggregatedLibrary]] = [:]
        for library in libraries {
            if byAccount[library.accountID] == nil { order.append(library.accountID) }
            byAccount[library.accountID, default: []].append(library)
        }
        return order.compactMap { accountID in
            guard let libs = byAccount[accountID], let first = libs.first else { return nil }
            return ServerGroup(
                id: accountID,
                serverName: first.serverName,
                providerKind: first.providerKind,
                libraries: libs
            )
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            OnboardingHeader(
                "Choose your libraries",
                subtitle: "Pick which libraries appear on your Home. You can turn any of these on or off anytime in Settings."
            )
            .padding(.bottom, 28)

            content

            Button {
                appState.confirmLibrarySelection()
            } label: {
                Text("Continue").frame(minWidth: 260)
            }
            .buttonStyle(.borderedProminent)
            .focused($focused, equals: .continueButton)
            .padding(.top, 24)
        }
        .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
        .padding(.vertical, 48)
        .frame(maxWidth: 900)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onExitCommand { appState.confirmLibrarySelection() }
        .task {
            await discovery.load(from: appState.resolvedAccounts(withIDs: appState.pendingLibrarySelectionAccountIDs))
        }
    }

    @ViewBuilder
    private var content: some View {
        switch discovery.state {
        case .idle, .loading:
            VStack(spacing: 16) {
                ProgressView()
                Text("Finding your libraries…")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .empty:
            Text("No libraries were found on the servers you added.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed:
            VStack(spacing: 16) {
                Text("Couldn't load your libraries.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Button {
                    Task { await discovery.load(from: appState.resolvedAccounts(withIDs: appState.pendingLibrarySelectionAccountIDs)) }
                } label: {
                    Label("Try Again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(SettingsFocusButtonStyle())
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case let .loaded(all):
            // Clipped scroll wrapped in a card (matching Settings). Inner gutters
            // give the row focus fill/shadow room so it isn't clipped by the card.
            PlozzScrollCard {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        ForEach(groups(from: all)) { group in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 12) {
                                    ProviderBrandMark(provider: group.providerKind, size: 30, showsBackground: false).frame(width: 34)
                                    Text(group.serverName)
                                        .font(.headline.weight(.semibold))
                                }
                                .padding(.horizontal, 20)

                                ForEach(group.libraries) { library in
                                    Toggle(isOn: Binding(
                                        get: { appState.homeLibraryVisibilityModel.isEnabled(library.key) },
                                        set: { appState.homeLibraryVisibilityModel.setEnabled($0, for: library.key) }
                                    )) {
                                        Text(library.library.title)
                                    }
                                    .toggleStyle(SettingsSwitchToggleStyle())
                                    .focused($focused, equals: .library(library.key))
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 40)
                    .padding(.vertical, 28)
                }
            }
        }
    }
}
#endif
