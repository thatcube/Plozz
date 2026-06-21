#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// tvOS server picker: discovered servers, last-used reconnect, and manual entry.
///
/// Uses native focusable controls (`List`, `Button`, `TextField`) so the focus
/// engine and Siri Remote work without custom handling.
public struct ServerPickerView: View {
    @State private var viewModel: ServerPickerViewModel
    @FocusState private var manualFieldFocused: Bool
    private let onSelect: (MediaServer) -> Void

    @MainActor
    public init(
        viewModel: ServerPickerViewModel? = nil,
        onSelect: @escaping (MediaServer) -> Void
    ) {
        _viewModel = State(initialValue: viewModel ?? ServerPickerViewModel())
        self.onSelect = onSelect
    }

    public var body: some View {
        NavigationStack {
            Form {
                if let last = viewModel.lastServer {
                    Section("Recently used") {
                        serverRow(last, subtitle: "Reconnect")
                    }
                }

                Section {
                    if viewModel.discoveredServers.isEmpty {
                        discoveredPlaceholder
                    } else {
                        ForEach(viewModel.discoveredServers) { server in
                            serverRow(server, subtitle: server.baseURL.host)
                        }
                    }
                } header: {
                    HStack {
                        Text("On your network")
                        Spacer()
                        if case .scanning = viewModel.phase { ProgressView() }
                    }
                }

                Section {
                    TextField("Server address", text: $viewModel.manualURLText)
                        .focused($manualFieldFocused)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                    Button("Connect") { Task { await connectManually() } }
                        .disabled(viewModel.manualURLText.isEmpty)
                } header: {
                    Text("Enter address")
                } footer: {
                    Text("Enter an IP address or full URL, e.g. 192.168.1.10 or jelly.example.com")
                }

                if case let .error(message) = viewModel.phase {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Choose your server")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        viewModel.startScan()
                    } label: {
                        Label("Rescan", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
        .onAppear { viewModel.startScan() }
        .onDisappear { viewModel.stopScan() }
    }

    private var discoveredPlaceholder: some View {
        Group {
            if case .scanning = viewModel.phase {
                Label("Searching for Jellyfin servers…", systemImage: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(.secondary)
            } else {
                Label("No servers found. Enter an address below.", systemImage: "magnifyingglass")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func serverRow(_ server: MediaServer, subtitle: String?) -> some View {
        Button {
            viewModel.select(server)
            onSelect(server)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(server.name).font(.headline)
                if let subtitle {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func connectManually() async {
        if let server = await viewModel.submitManualURL() {
            onSelect(server)
        }
    }
}

#endif
