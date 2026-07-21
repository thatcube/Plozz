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

            switch model.phase {
            case .idle:
                setupSection
            case .connecting, .sending:
                Section { HStack { ProgressView(); Text("Setting up your device…").foregroundStyle(.secondary) } }
            case .sent:
                Section {
                    Label("Your device is set up — it’s signed in with no typing.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                .task { try? await Task.sleep(nanoseconds: 2_500_000_000); handled = false; model.reset() }
            case .failed(let message):
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Button("Try Again") { handled = false; model.reset(); model.startDiscovery() }
                }
            default:
                EmptyView()
            }
        }
        .navigationTitle("Sync & Setup")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.startDiscovery() }
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

    @ViewBuilder
    private var setupSection: some View {
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
#endif
