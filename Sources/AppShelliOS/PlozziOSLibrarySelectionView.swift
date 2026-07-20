#if os(iOS)
import AppRuntime
import CoreModels
import CoreUI
import SwiftUI

struct PlozziOSLibrarySelectionView: View {
    let accounts: [ResolvedAccount]
    @Bindable var visibility: HomeLibraryVisibilityModel
    let onContinue: () -> Void

    @State private var libraries: [LibraryChoice] = []
    @State private var isLoading = true
    @State private var loadFailed = false
    @State private var loadGeneration = 0

    var body: some View {
        NavigationStack {
            Form {
                content

                Section {
                    Button("Continue", action: onContinue)
                        .frame(maxWidth: .infinity)
                } footer: {
                    Text("You can change these choices later in Settings.")
                }
            }
            .settingsPageSurface()
            .navigationTitle("Choose Your Libraries")
            .navigationBarTitleDisplayMode(.inline)
            .task { await loadLibraries() }
        }
        .interactiveDismissDisabled()
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            Section {
                HStack {
                    ProgressView()
                    Text("Finding your libraries…")
                }
            }
        } else if libraries.isEmpty {
            Section {
                ContentUnavailableView(
                    loadFailed ? "Couldn’t Load Libraries" : "No Video Libraries",
                    systemImage: loadFailed
                        ? "exclamationmark.triangle"
                        : "rectangle.stack"
                )
                if loadFailed {
                    Button("Try Again", systemImage: "arrow.clockwise") {
                        Task { await loadLibraries() }
                    }
                }
            }
        } else {
            ForEach(groupedLibraries) { group in
                Section(group.serverName) {
                    ForEach(group.libraries) { library in
                        Toggle(
                            library.library.title,
                            isOn: Binding(
                                get: {
                                    visibility.isEnabled(library.key)
                                },
                                set: {
                                    visibility.setEnabled($0, for: library.key)
                                }
                            )
                        )
                    }
                }
            }

            if loadFailed {
                Section {
                    Label(
                        "Some servers could not be reached. Their libraries can be configured later in Settings.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var groupedLibraries: [LibraryGroup] {
        var order: [String] = []
        var grouped: [String: [LibraryChoice]] = [:]
        for library in libraries {
            if grouped[library.accountID] == nil {
                order.append(library.accountID)
            }
            grouped[library.accountID, default: []].append(library)
        }
        return order.compactMap { accountID in
            guard let choices = grouped[accountID],
                  let first = choices.first else { return nil }
            return LibraryGroup(
                id: accountID,
                serverName: first.serverName,
                libraries: choices
            )
        }
    }

    @MainActor
    private func loadLibraries() async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        loadFailed = false
        var loaded: [LibraryChoice] = []
        for account in accounts {
            do {
                let accountLibraries = try await account.provider.libraries()
                loaded.append(
                    contentsOf: accountLibraries
                        .filter { !$0.isMusic }
                        .map {
                            LibraryChoice(
                                accountID: account.account.id,
                                serverName: account.account.server.name,
                                library: $0
                            )
                        }
                )
            } catch is CancellationError {
                guard generation == loadGeneration else { return }
                isLoading = false
                return
            } catch {
                guard generation == loadGeneration else { return }
                loadFailed = true
            }
        }
        guard generation == loadGeneration else { return }
        libraries = loaded
        isLoading = false
    }
}

private struct LibraryChoice: Identifiable {
    let accountID: String
    let serverName: String
    let library: MediaLibrary

    var id: String { key }
    var key: String { "\(accountID):\(library.id)" }
}

private struct LibraryGroup: Identifiable {
    let id: String
    let serverName: String
    let libraries: [LibraryChoice]
}
#endif
