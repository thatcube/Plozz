#if os(iOS)
import SwiftUI
import FeatureSyncSetup

/// Dedicated Sync & Setup settings page (a normal navigation destination like the
/// other settings rows), instead of a large inline block.
@MainActor
struct PlozziOSSyncSetupSettingsView: View {
    let appModel: PlozziOSAppModel
    @State private var showSyncSendSheet = false

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

            Section {
                Button {
                    showSyncSendSheet = true
                } label: {
                    Label("Set up another device", systemImage: "qrcode.viewfinder")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } footer: {
                Text("Signs your Apple TV, iPad, or another device in by scanning the code it shows — or by typing its short code. No re-typing passwords.")
            }
        }
        .navigationTitle("Sync & Setup")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showSyncSendSheet) {
            SyncSetupSendView(appModel: appModel) { showSyncSendSheet = false }
        }
    }
}
#endif
