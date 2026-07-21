#if os(tvOS)
import SwiftUI
import CoreImage.CIFilterBuiltins
import FeatureSyncSetup

/// tvOS "Set up from another device" screen: shows a QR + short code, advertises
/// over the local network, receives the sealed setup, and persists it so the TV is
/// signed in with no typing.
@MainActor
struct SyncSetupReceiveView: View {
    private let appState: AppState
    private let onClose: () -> Void
    @State private var model: SyncSetupPairingModel
    @State private var didApply = false

    init(appState: AppState, onClose: @escaping () -> Void) {
        self.appState = appState
        self.onClose = onClose
        _model = State(initialValue: SyncSetupPairingModel(service: appState.syncSetup))
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.10), Color(white: 0.03)],
                           startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await model.startReceiving() }
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 28) {
            switch model.phase {
            case .idle:
                ProgressView()
            case .waitingForPeer(let code, let invite):
                Text("Set up from another device").font(.largeTitle.bold())
                HStack(alignment: .center, spacing: 60) {
                    if let img = Self.qrImage(invite.encoded()) {
                        VStack(spacing: 12) {
                            Image(uiImage: img).interpolation(.none).resizable()
                                .frame(width: 340, height: 340)
                                .padding(18).background(.white).cornerRadius(16)
                            Text("Scan with your phone or tablet").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    VStack(spacing: 10) {
                        Text("or enter code").font(.callout).foregroundStyle(.secondary)
                        Text(SyncPairingCode.grouped(code))
                            .font(.system(size: 56, weight: .bold, design: .rounded)).monospaced()
                        Text("on another device").font(.callout).foregroundStyle(.secondary)
                    }
                }
                Text("On your other device, open Plozz ▸ Settings ▸ Sync & Setup ▸ “Set up another device.”")
                    .font(.headline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 900)
            case .applying:
                ProgressView("Setting up…").font(.title2)
            case .applied(let received):
                VStack(spacing: 16) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 90)).foregroundStyle(.green)
                    Text("You’re all set").font(.title.bold())
                    Text(summary(received)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).frame(maxWidth: 760)
                }
                .onAppear {
                    guard !didApply else { return }
                    didApply = true
                    appState.applyReceivedSetup(received)
                    Task { try? await Task.sleep(nanoseconds: 1_800_000_000); onClose() }
                }
            case .connecting, .sending, .sent:
                ProgressView()
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle").font(.system(size: 60)).foregroundStyle(.orange)
                Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Try Again") { Task { await model.startReceiving() } }
            }

            if case .applied = model.phase {} else {
                Button("Cancel", role: .cancel) { onClose() }.padding(.top, 12)
            }
        }
        .padding(70)
    }

    private func summary(_ received: SyncSetupService.ReceivedSetup) -> String {
        let servers = received.application.authorizedAuthorizations.count
        let profiles = received.config.profiles.count
        var parts: [String] = [servers == 1 ? "Signed in to 1 server" : "Signed in to \(servers) servers"]
        if profiles > 0 { parts.append(profiles == 1 ? "1 profile" : "\(profiles) profiles") }
        return parts.joined(separator: " · ")
    }

    static func qrImage(_ string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)) else { return nil }
        let context = CIContext()
        guard let cg = context.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
#endif
