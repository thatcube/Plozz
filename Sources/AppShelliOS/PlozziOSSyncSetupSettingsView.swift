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
    @State private var showReceive = false
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
            case .confirmingSAS(let code):
                sasConfirm(code)
            case .failed(let message):
                centered {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 60)).foregroundStyle(.orange)
                    Text("Setup didn’t finish").font(.title3.bold())
                    Text(message).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).padding(.horizontal)
                    Button("Try Again") { handled = false; model.reset(); model.startDiscovery() }
                        .syncPrimaryButtonStyle()
                }
            default:
                centered { ProgressView() }
            }
        }
        .navigationTitle("Sync & Setup")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if case .idle = model.phase { model.startDiscovery() } }
        .onDisappear { model.stopDiscovery() }
        .fullScreenCover(isPresented: $showReceive) {
            PlozziOSSyncSetupReceiveView(appModel: appModel) { showReceive = false }
        }
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

    @ViewBuilder
    private func sasConfirm(_ code: String) -> some View {
        SyncSetupSASConfirmView(code: code) { model.confirmSASMatch($0) }
    }

    private var successView: some View {
        SyncSetupSentSuccessView(
            accounts: appModel.accounts,
            profiles: appModel.profiles.profiles,
            onDone: {
                handled = false
                model.reset()
                model.startDiscovery()
            }
        )
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
                    set: { appModel.setSyncSetupEnabled($0) }
                )) {
                    Label("iCloud Sync", systemImage: "icloud")
                }
                if appModel.syncSetup.isEnabled {
                    HStack {
                        Text(appModel.cloudSyncStatus.summary)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Sync Now") { appModel.syncCloudNow() }
                            .font(.footnote.weight(.semibold))
                    }
                }
            } footer: {
                Text("Keeps your profiles, settings, and server list in sync across every device signed in to your iCloud account, through your private iCloud. Your logins stay private to each device. Off by default.")
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

            Section {
                Button { showReceive = true } label: {
                    Label("Set up this device from another", systemImage: "qrcode")
                }
            } header: {
                Text("Set up this device")
            } footer: {
                Text("Coming from a device that’s already signed in? Show a code here and scan it from your other phone, tablet, or Apple TV to sign this one in.")
            }
        }
    }
}
#endif
