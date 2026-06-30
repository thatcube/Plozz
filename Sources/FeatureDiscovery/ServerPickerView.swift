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
                        serverRow(last, subtitle: lastServerSubtitle)
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

                if viewModel.isOnTailscale {
                    Section {
                        tailscaleGuidance
                    } header: {
                        Text("Tailscale")
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
            } else if viewModel.lastServerReachable == true {
                // The saved server above is confirmed online, so an empty
                // discovered list isn't a dead end — point the user up.
                Label("Your saved server above is online and ready.", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            } else {
                Label("No servers found yet. Make sure your Jellyfin server is on and that Plozz is allowed Local Network access (tvOS Settings ▸ General ▸ Privacy), then rescan — or enter an address below.", systemImage: "magnifyingglass")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Tailscale-specific guidance, shown only when this Apple TV is on a
    /// tailnet. Explains how to reach a Jellyfin server over Tailscale, since
    /// such servers can't be auto-discovered from a sandboxed tvOS app.
    private var tailscaleGuidance: some View {
        HStack(alignment: .top, spacing: 24) {
            TailscaleLogo()
                .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 8) {
                Text("This Apple TV is on Tailscale")
                    .font(.headline)
                Text("Enter your server's Tailscale address in the field below — either its Tailscale IP (e.g. 100.101.102.103:8096) or its MagicDNS name (e.g. jellyfin.your-tailnet.ts.net).")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let ip = viewModel.tailscaleIP {
                    Label("This device: \(ip)", systemImage: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.green)
                }
            }
        }
        .padding(.vertical, 8)
    }

    /// Subtitle for the saved server, reflecting live reachability.
    private var lastServerSubtitle: String {
        switch viewModel.lastServerReachable {
        case .some(true): return "Reconnect · On your network"
        case .some(false): return "Reconnect · Offline right now"
        case .none: return "Reconnect"
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
