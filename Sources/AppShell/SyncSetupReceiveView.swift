#if os(tvOS)
import SwiftUI
import CoreImage.CIFilterBuiltins
import FeatureSyncSetup

/// tvOS "Set up from your iPhone" screen: shows a QR the phone scans, advertises
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
        VStack(spacing: 28) {
            switch model.phase {
            case .idle:
                ProgressView()
            case .waitingForPhone(let invite):
                Text("Set up from your iPhone").font(.largeTitle.bold())
                if let img = Self.qrImage(invite.encoded()) {
                    Image(uiImage: img).interpolation(.none).resizable()
                        .frame(width: 380, height: 380)
                        .padding(20).background(.white).cornerRadius(16)
                }
                Text("On your iPhone open Plozz ▸ Settings ▸ Sync & Setup ▸ “Set up another device,” then point the camera at this code.")
                    .font(.headline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 760)
            case .applying:
                ProgressView("Setting up…").font(.title2)
            case .applied(let received):
                VStack(spacing: 16) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 90)).foregroundStyle(.green)
                    Text("You’re all set").font(.title.bold())
                    Text("Signed in to \(received.application.authorizedAuthorizations.count) server(s).")
                        .foregroundStyle(.secondary)
                    Button("Done") { onClose() }.buttonStyle(.borderedProminent)
                }
                .onAppear {
                    guard !didApply else { return }
                    didApply = true
                    appState.applyReceivedSetup(received)
                }
            case .sending, .sent:
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
        .task { await model.startReceiving() }
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
