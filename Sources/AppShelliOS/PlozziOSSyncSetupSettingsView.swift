#if os(iOS)
import CoreUI
import FeatureSettings
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
                    Text("Setting up your device…").font(.headline).plozzForeground(.secondary)
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
                    Text(message).plozzForeground(.secondary)
                        .multilineTextAlignment(.center).padding(.horizontal)
                    Button("Try Again") { handled = false; model.reset(); model.startDiscovery() }
                        .syncPrimaryButtonStyle()
                }
            default:
                centered { ProgressView() }
            }
        }
        .navigationTitle("iCloud Sync")
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
        SettingsPageList {
            SettingsSectionGroup {
                Toggle(isOn: Binding(
                    get: { appModel.syncSetup.isEnabled },
                    set: { appModel.setSyncSetupEnabled($0) }
                )) {
                    Label("iCloud Sync", systemImage: "icloud")
                }
                if appModel.syncSetup.isEnabled {
                    HStack {
                        SyncStatusLine(provider: syncStatusProvider)
                            .font(.footnote)
                            .plozzForeground(.secondary)
                        Spacer()
                        Button("Sync Now") { appModel.syncCloudNow() }
                            .font(.footnote.weight(.semibold))
                    }
                }
            } footer: {
                Text("Syncs profiles, settings, and servers. Logins stay on each device.")
            }

            SettingsSectionGroup("Set Up Another Device") {
                if model.nearbyDevices.isEmpty {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Looking for nearby devices…")
                            .plozzForeground(.secondary)
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
                                        .font(.footnote).plozzForeground(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.forward").plozzForeground(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                Button { showScanner = true } label: {
                    Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                }
                Button { showCodeEntry = true } label: {
                    Label("Enter Code", systemImage: "keyboard")
                }
            } footer: {
                Text("Choose a nearby device, or scan its code.")
            }

            SettingsSectionGroup("This Device") {
                Button { showReceive = true } label: {
                    Label("Set Up From Another Device", systemImage: "qrcode")
                }
            }

            if !appModel.pendingSyncedServers.isEmpty {
                SettingsSectionGroup("Servers to Set Up") {
                    ForEach(appModel.pendingSyncedServers, id: \.id) { server in
                        HStack(spacing: 12) {
                            Image(systemName: "externaldrive.badge.person.crop")
                                .font(.title3)
                                .plozzForeground(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(server.serverName).fontWeight(.medium)
                                Text("Needs sign-in")
                                    .font(.footnote)
                                    .plozzForeground(.secondary)
                            }
                            Spacer()
                            Button("Ignore") {
                                appModel.ignorePendingSyncedServer(server.id)
                            }
                            .font(.footnote)
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }

            if appModel.syncSetup.isEnabled {
                SettingsSectionGroup {
                    NavigationLink {
                        PlozziOSSyncTroubleshootingView(appModel: appModel)
                    } label: {
                        Label(
                            "Troubleshooting",
                            systemImage: "wrench.and.screwdriver"
                        )
                    }
                }
            }
        }
    }

    private var syncStatusProvider: SyncStatusProvider {
        SyncStatusProvider {
            SyncStatusPresentation(
                summary: appModel.cloudSyncStatus.summary,
                isSyncing: appModel.cloudSyncStatus.phase == .syncing,
                itemCount: appModel.cloudSyncStatus.syncedRecordCount,
                accountTag: appModel.cloudSyncStatus.accountTag
            )
        }
    }
}

private struct PlozziOSSyncTroubleshootingView: View {
    let appModel: PlozziOSAppModel
    @State private var showResetConfirm = false

    var body: some View {
        SettingsPageList {
            SettingsSectionGroup("Compare Devices") {
                LabeledContent("iCloud items") {
                    Text(verbatim: appModel.cloudSyncStatus.syncedRecordCount?.formatted() ?? "—")
                }
                LabeledContent("iCloud account") {
                    Text(
                        verbatim: appModel.cloudSyncStatus.accountTag.map {
                            "\($0)…"
                        } ?? "—"
                    )
                }
            } footer: {
                Text("These should match on every device.")
            }

            SettingsSectionGroup("Recovery") {
                Button {
                    appModel.redownloadCloudSync()
                } label: {
                    Label("Reload From iCloud", systemImage: "arrow.down.circle")
                }
                Button(role: .destructive) {
                    showResetConfirm = true
                } label: {
                    Label("Reset Sync", systemImage: "arrow.counterclockwise.icloud")
                }
            } footer: {
                Text("Try Reload first. Reset only if changes are still missing.")
            }
        }
        .navigationTitle("Troubleshooting")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Reset synced data?",
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button("Reset & Re-upload From This Device", role: .destructive) {
                appModel.resetCloudSync()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Replaces iCloud data with this device’s copy. Other devices keep their logins.")
        }
    }
}
#endif
