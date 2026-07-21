#if os(iOS)
import SwiftUI
import AVFoundation
import FeatureSyncSetup

/// iOS "Set up another device" screen: scans the QR shown on the Apple TV and
/// sends this phone's config + credentials over the E2E pairing channel so the TV
/// is signed in with no typing.
@MainActor
struct SyncSetupSendView: View {
    private let appModel: PlozziOSAppModel
    private let onClose: () -> Void
    @State private var model: SyncSetupPairingModel
    @State private var handled = false

    init(appModel: PlozziOSAppModel, onClose: @escaping () -> Void) {
        self.appModel = appModel
        self.onClose = onClose
        _model = State(initialValue: SyncSetupPairingModel(service: appModel.syncSetup))
    }

    var body: some View {
        NavigationStack {
            Group {
                switch model.phase {
                case .idle:
                    ZStack {
                        QRScannerView { code in
                            guard !handled else { return }
                            handled = true
                            Task { await model.send(inviteString: code) }
                        }
                        .ignoresSafeArea()
                        VStack {
                            Spacer()
                            Text("Point your camera at the code on your Apple TV")
                                .font(.headline).padding()
                                .background(.ultraThinMaterial, in: Capsule())
                                .padding(.bottom, 60)
                        }
                    }
                case .sending:
                    ProgressView("Sending your setup…")
                case .sent:
                    result(icon: "checkmark.circle.fill", color: .green,
                           title: "Your Apple TV is set up",
                           subtitle: "It’s signed in — no typing needed.")
                        .task {
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            onClose()
                        }
                case .failed(let message):
                    result(icon: "exclamationmark.triangle.fill", color: .orange,
                           title: "Setup didn’t finish", subtitle: message, retry: true)
                default:
                    ProgressView()
                }
            }
            .navigationTitle("Set Up Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { onClose() } } }
        }
    }

    @ViewBuilder
    private func result(icon: String, color: Color, title: String, subtitle: String, retry: Bool = false) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon).font(.system(size: 64)).foregroundStyle(color)
            Text(title).font(.title2.bold())
            Text(subtitle).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal)
            if retry {
                Button("Try Again") { handled = false; model.reset() }.buttonStyle(.borderedProminent)
            } else {
                Button("Done") { onClose() }.buttonStyle(.borderedProminent)
            }
        }.padding()
    }
}

/// Minimal AVFoundation QR scanner.
struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerVC {
        let vc = ScannerVC()
        vc.onCode = onCode
        return vc
    }
    func updateUIViewController(_ uiViewController: ScannerVC, context: Context) {}

    final class ScannerVC: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: ((String) -> Void)?
        private let session = AVCaptureSession()
        private var preview: AVCaptureVideoPreviewLayer?

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else { return }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = .resizeAspectFill
            preview.frame = view.layer.bounds
            view.layer.addSublayer(preview)
            self.preview = preview
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            if !session.isRunning { DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() } }
        }
        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            preview?.frame = view.layer.bounds
        }
        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            if session.isRunning { session.stopRunning() }
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput,
                            didOutput metadataObjects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  let value = obj.stringValue else { return }
            session.stopRunning()
            onCode?(value)
        }
    }
}
#endif
