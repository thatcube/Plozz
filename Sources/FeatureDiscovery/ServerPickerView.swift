#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// tvOS server picker: discovered servers, last-used reconnect, and manual entry.
///
/// Uses native focusable controls (`List`, `Button`, `TextField`) so the focus
/// engine and Siri Remote work without custom handling.
public struct ServerPickerView: View {
    @State private var viewModel: ServerPickerViewModel
    @FocusState private var manualFieldFocused: Bool
    private let onSelect: (MediaServer) -> Void
    /// Invoked when the user backs out — the in-bounds Back button or the Siri
    /// Remote's Menu button. `nil` hides the Back button and lets Menu fall
    /// through. Onboarding passes a closure that returns to the provider
    /// chooser, so Menu no longer quits the app from this screen.
    private let onBack: (() -> Void)?

    @MainActor
    public init(
        viewModel: ServerPickerViewModel? = nil,
        onBack: (() -> Void)? = nil,
        onSelect: @escaping (MediaServer) -> Void
    ) {
        _viewModel = State(initialValue: viewModel ?? ServerPickerViewModel())
        self.onBack = onBack
        self.onSelect = onSelect
    }


    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header

                if let last = viewModel.lastServer {
                    PickerPanel(title: "Recently used") {
                        serverRow(last, subtitle: lastServerSubtitle)
                    }
                }

                PickerPanel(title: "On your network", titleAccessory: { scanIndicator }) {
                    if viewModel.discoveredServers.isEmpty {
                        discoveredPlaceholder
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 12)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(viewModel.discoveredServers.enumerated()), id: \.element) { idx, server in
                                if idx > 0 { Divider() }
                                serverRow(server, subtitle: server.baseURL.host)
                            }
                        }
                    }
                }

                if viewModel.isOnTailscale {
                    PickerPanel(title: "Tailscale") {
                        tailscaleGuidance
                    }
                }

                PickerPanel(
                    title: "Enter address",
                    footer: "Enter an IP address or full URL, e.g. 192.168.1.10 or jelly.example.com"
                ) {
                    VStack(alignment: .leading, spacing: 18) {
                        TextField("Server address", text: $viewModel.manualURLText)
                            .focused($manualFieldFocused)
                            .textContentType(.URL)
                            .autocorrectionDisabled()
                        Button("Connect") { Task { await connectManually() } }
                            .disabled(viewModel.manualURLText.isEmpty)
                    }
                }

                if case let .error(message) = viewModel.phase {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }
            }
            // Match the Settings pages: cap the column at the shared content
            // width and center it, with screen-padding gutters on each side so
            // the outward focus lift/shadow has room to breathe.
            .frame(maxWidth: PlozzTheme.Metrics.settingsContentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
            .padding(.vertical, 32)
        }
        // Never clip the outward-growing focus highlight/shadow at the
        // width-capped column edges (same reason the Settings pages disable it).
        .scrollClipDisabled()
        // The Siri Remote's Menu/back button steps back to the provider chooser
        // instead of quitting the app.
        .onExitCommand { onBack?() }
        .onAppear { viewModel.startScan() }
        .onDisappear { viewModel.stopScan() }
    }

    // MARK: - Header (in-bounds Back + Rescan)

    private var header: some View {
        HStack {
            if let onBack {
                Button(action: onBack) {
                    Label("Back", systemImage: "chevron.backward")
                }
                .buttonStyle(.bordered)
            }
            Spacer(minLength: 24)
            Button { viewModel.startScan() } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
        }
    }

    /// Small trailing spinner shown beside the "On your network" header while a
    /// scan is in flight.
    @ViewBuilder
    private var scanIndicator: some View {
        if case .scanning = viewModel.phase { ProgressView() }
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

    /// Tailscale guidance, shown only when this Apple TV is on a tailnet. Its
    /// real purpose is to tell you Tailscale servers can't be auto-discovered
    /// and must be entered manually.
    private var tailscaleGuidance: some View {
        HStack(alignment: .top, spacing: 24) {
            TailscaleLogo()
                .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 8) {
                Text("Tailscale servers can't be found automatically.")
                    .font(.headline)
                Text("Type your server's Tailscale IP or MagicDNS name in the address field below.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
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
            // Logo top-aligned with the server name so it lines up with the
            // first line when a name/address wraps to two lines.
            HStack(alignment: .top, spacing: 20) {
                ProviderBrandMark(provider: server.provider, size: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(server.name).font(.headline)
                    if let subtitle {
                        Text(subtitle).font(.subheadline).settingsRowSecondary()
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsFocusButtonStyle(size: .prominent))
    }

    private func connectManually() async {
        if let server = await viewModel.submitManualURL() {
            onSelect(server)
        }
    }
}

/// A titled `.ultraThinMaterial` card matching the Settings pages' `SettingsPanel`
/// (uppercase secondary header, optional trailing accessory + footer). Kept local
/// to FeatureDiscovery so the picker reads as Settings without depending on it.
private struct PickerPanel<Content: View, Accessory: View>: View {
    var title: String? = nil
    var footer: String? = nil
    var titleAccessory: () -> Accessory
    var content: () -> Content

    init(
        title: String? = nil,
        footer: String? = nil,
        @ViewBuilder titleAccessory: @escaping () -> Accessory = { EmptyView() },
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.footer = footer
        self.titleAccessory = titleAccessory
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if title != nil {
                HStack {
                    if let title {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .textCase(.uppercase)
                            .tracking(1.0)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    titleAccessory()
                }
            }
            content()
            if let footer {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(28)
        .background(
            RoundedRectangle(cornerRadius: PlozzTheme.Metrics.mediumCardCornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: PlozzTheme.Metrics.mediumCardCornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

#endif
