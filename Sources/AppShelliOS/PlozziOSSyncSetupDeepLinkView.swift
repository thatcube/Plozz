#if os(iOS)
import SwiftUI
import FeatureSyncSetup

/// Focused pairing send flow presented when the app is opened from a Sync & Setup
/// universal link (`https://plozz.app/pair#…`). It immediately sends this device's
/// setup to the device that showed the QR, showing progress → success/failure,
/// so the user lands exactly where they intended with no extra taps.
@MainActor
struct PlozziOSSyncSetupDeepLinkView: View {
    let appModel: PlozziOSAppModel
    let invite: String
    let onClose: () -> Void
    @State private var model: SyncSetupPairingModel
    @State private var started = false

    init(appModel: PlozziOSAppModel, invite: String, onClose: @escaping () -> Void) {
        self.appModel = appModel
        self.invite = invite
        self.onClose = onClose
        _model = State(initialValue: SyncSetupPairingModel(service: appModel.syncSetup))
    }

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
                .navigationTitle("Set Up Device")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        if case .sent = model.phase { EmptyView() } else {
                            Button("Cancel") { onClose() }
                        }
                    }
                }
        }
        .task {
            guard !started else { return }
            started = true
            await model.send(inviteString: invite)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .sent:
            VStack(spacing: 18) {
                Spacer()
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 84)).foregroundStyle(.green)
                Text("Device is set up").font(.title.bold())
                Text("It’s signed in — no typing needed on the other device.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Spacer()
                Button("Done", action: onClose)
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .padding(.bottom, 24)
            }
        case .failed(let message):
            VStack(spacing: 16) {
                Spacer()
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 60)).foregroundStyle(.orange)
                Text("Setup didn’t finish").font(.title3.bold())
                Text(message).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal)
                Spacer()
                Button("Try Again") {
                    Task {
                        model.reset()
                        await model.send(inviteString: invite)
                    }
                }
                .buttonStyle(.borderedProminent)
                .padding(.bottom, 24)
            }
        default:
            VStack(spacing: 16) {
                ProgressView().controlSize(.large)
                Text("Setting up the other device…")
                    .font(.headline).foregroundStyle(.secondary)
            }
        }
    }
}
#endif
