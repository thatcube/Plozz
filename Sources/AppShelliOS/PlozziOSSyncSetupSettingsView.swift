#if os(iOS)
import SwiftUI
import FeatureSyncSetup

/// Dedicated Sync & Setup settings page. The device-setup flow lives directly on
/// this page (no extra tap): opening it starts discovering nearby devices to pair.
@MainActor
struct PlozziOSSyncSetupSettingsView: View {
    let appModel: PlozziOSAppModel
    @State private var model: SyncSetupPairingModel
    @State private var showScanner = false
    @State private var showCodeEntry = false
    @State private var handled = false

    init(appModel: PlozziOSAppModel) {
        self.appModel = appModel
        _model = State(initialValue: SyncSetupPairingModel(service: appModel.syncSetup))
    }

    var body: some View {
        Group {
            switch model.phase {
            case .idle:
                idleList
            case .connecting, .sending:
                centered {
                    ProgressView().controlSize(.large)
                    Text("Setting up your device…").font(.headline).foregroundStyle(.secondary)
                }
            case .sent:
                successView
            case .failed(let message):
                centered {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 60)).foregroundStyle(.orange)
                    Text("Setup didn’t finish").font(.title3.bold())
                    Text(message).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).padding(.horizontal)
                    Button("Try Again") { handled = false; model.reset(); model.startDiscovery() }
                        .buttonStyle(.borderedProminent)
                }
            default:
                centered { ProgressView() }
            }
        }
        .navigationTitle("Sync & Setup")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if case .idle = model.phase { model.startDiscovery() } }
        .onDisappear { model.stopDiscovery() }
        .fullScreenCover(isPresented: $showScanner) {
            SyncSetupScannerScreen(
                onCode: { code in
                    showScanner = false
                    guard !handled else { return }
                    handled = true
                    Task { await model.send(inviteString: code) }
                },
                onCancel: { showScanner = false }
            )
        }
        .sheet(isPresented: $showCodeEntry) {
            SyncSetupCodeEntryScreen(
                onSubmit: { code in
                    showCodeEntry = false
                    guard !handled else { return }
                    handled = true
                    Task { await model.send(code: code) }
                },
                onCancel: { showCodeEntry = false }
            )
        }
    }

    // MARK: Success

    private var successView: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 84)).foregroundStyle(.green)
            Text("Your device is set up").font(.title.bold())
            Text("It’s signed in — no typing needed on the other device.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            if let sent = sentSummary {
                Text(sent).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") {
                handled = false
                model.reset()
                model.startDiscovery()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sentSummary: String? {
        let servers = Set(appModel.accounts.map(\.server.id)).count
        let profiles = appModel.profiles.profiles.count
        guard servers > 0 || profiles > 0 else { return nil }
        var parts: [String] = []
        if servers > 0 { parts.append(servers == 1 ? "1 server" : "\(servers) servers") }
        if profiles > 0 { parts.append(profiles == 1 ? "1 profile" : "\(profiles) profiles") }
        return "Sent " + parts.joined(separator: " and ")
    }

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 16) { content() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
    }

    // MARK: Idle list

    private var idleList: some View {
        List {
            Section {
                Toggle(isOn: Binding(
                    get: { appModel.syncSetup.isEnabled },
                    set: { appModel.syncSetup.setEnabled($0) }
                )) {
                    Label("Sync across your devices", systemImage: "arrow.triangle.2.circlepath")
                }
            } footer: {
                Text("Securely syncs your profiles and settings through your private iCloud (end-to-end encrypted). Off by default.")
            }

            Section {
                if model.nearbyDevices.isEmpty {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Looking for a device to set up…").foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(model.nearbyDevices) { device in
                        Button {
                            guard !handled else { return }
                            handled = true
                            Task { await model.pair(with: device) }
                        } label: {
                            HStack {
                                Image(systemName: "tv").font(.title3)
                                VStack(alignment: .leading) {
                                    Text(device.displayName).fontWeight(.semibold)
                                    Text("Code \(SyncPairingCode.grouped(device.serviceName))")
                                        .font(.footnote).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                Text("Set up another device")
            } footer: {
                Text("On your Apple TV, iPad, or another device, open Plozz and choose “Set up from another device.” It’ll appear here — tap to sign it in. Both devices must be on the same Wi-Fi.")
            }

            Section {
                Button { showScanner = true } label: {
                    Label("Scan QR code", systemImage: "qrcode.viewfinder")
                }
                Button { showCodeEntry = true } label: {
                    Label("Enter code manually", systemImage: "keyboard")
                }
            } footer: {
                Text("Not seeing it nearby? Scan the QR or type the short code shown on the other device.")
            }
        }
    }
}
#endif
