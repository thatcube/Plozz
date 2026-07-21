#if os(iOS)
import SwiftUI
import AVFoundation
import FeatureSyncSetup

/// iOS "Set up another device" screen: scan the QR shown on the other device, or
/// type its short code, then send this device's config + credentials over the E2E
/// pairing channel so the other device is set up with no typing.
@MainActor
struct SyncSetupSendView: View {
    private let appModel: PlozziOSAppModel
    private let onClose: () -> Void
    @State private var model: SyncSetupPairingModel
    @State private var handled = false
    @State private var mode: Mode = .nearby
    @State private var typedCode = ""

    enum Mode { case nearby, scan, code }

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
                    switch mode {
                    case .nearby: nearby
                    case .scan: scanner
                    case .code: codeEntry
                    }
                case .connecting:
                    ProgressView("Connecting…")
                case .sending:
                    ProgressView("Sending your setup…")
                case .sent:
                    result(icon: "checkmark.circle.fill", color: .green,
                           title: "Your other device is set up",
                           subtitle: "It’s signed in — no typing needed.")
                        .task { try? await Task.sleep(nanoseconds: 2_000_000_000); onClose() }
                case .failed(let message):
                    result(icon: "exclamationmark.triangle.fill", color: .orange,
                           title: "Setup didn’t finish", subtitle: message, retry: true)
                default:
                    ProgressView()
                }
            }
            .navigationTitle("Set Up Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { model.stopDiscovery(); onClose() } }
                if model.phase == .idle {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button { switchMode(.nearby) } label: { Label("Nearby", systemImage: "wifi") }
                            Button { switchMode(.scan) } label: { Label("Scan QR", systemImage: "qrcode.viewfinder") }
                            Button { switchMode(.code) } label: { Label("Enter Code", systemImage: "keyboard") }
                        } label: { Image(systemName: "ellipsis.circle") }
                    }
                }
            }
            .onAppear { if mode == .nearby { model.startDiscovery() } }
            .onDisappear { model.stopDiscovery() }
        }
    }

    private func switchMode(_ new: Mode) {
        if new == .nearby { model.startDiscovery() } else { model.stopDiscovery() }
        mode = new
    }

    private var nearby: some View {
        VStack(spacing: 0) {
            if model.nearbyDevices.isEmpty {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("Looking for a device waiting to be set up…").font(.headline)
                        .multilineTextAlignment(.center)
                    Text("On the other device, open Plozz and choose “Set up from another device.” Make sure both are on the same Wi-Fi.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding(40)
            } else {
                List(model.nearbyDevices) { device in
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
                    }
                }
            }
        }
    }

    private var scanner: some View {
        ZStack {
            QRScannerView { code in
                guard !handled else { return }
                handled = true
                Task { await model.send(inviteString: code) }
            }
            .ignoresSafeArea()
            VStack {
                Spacer()
                Text("Point your camera at the code on your other device — pinch to zoom")
                    .font(.headline).padding()
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 60)
            }
        }
    }

    private var codeEntry: some View {
        VStack(spacing: 20) {
            Image(systemName: "keyboard").font(.system(size: 48)).foregroundStyle(.tint)
            Text("Enter the code shown on your other device").font(.headline)
                .multilineTextAlignment(.center)
            TextField("Code", text: $typedCode)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .multilineTextAlignment(.center)
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 40)
            Button("Continue") {
                guard !handled else { return }
                handled = true
                Task { await model.send(code: typedCode) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(SyncPairingCode.normalize(typedCode).count < 4)
            Spacer()
        }
        .padding(.top, 60)
    }

    @ViewBuilder
    private func result(icon: String, color: Color, title: String, subtitle: String, retry: Bool = false) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon).font(.system(size: 64)).foregroundStyle(color)
            Text(title).font(.title2.bold())
            Text(subtitle).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal)
            if retry {
                Button("Try Again") { handled = false; typedCode = ""; model.reset() }.buttonStyle(.borderedProminent)
            } else {
                Button("Done") { onClose() }.buttonStyle(.borderedProminent)
            }
        }.padding()
    }
}

/// Minimal AVFoundation QR scanner with pinch-to-zoom.
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
        private var device: AVCaptureDevice?
        private var zoomAtPinchStart: CGFloat = 1.0

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else { return }
            self.device = device
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
            view.addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:))))
        }

        @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            guard let device else { return }
            if gesture.state == .began { zoomAtPinchStart = device.videoZoomFactor }
            let maxZoom = min(device.activeFormat.videoMaxZoomFactor, 8.0)
            let target = max(1.0, min(zoomAtPinchStart * gesture.scale, maxZoom))
            do { try device.lockForConfiguration(); device.videoZoomFactor = target; device.unlockForConfiguration() } catch {}
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            if !session.isRunning { DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() } }
        }
        override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); preview?.frame = view.layer.bounds }
        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            if session.isRunning { session.stopRunning() }
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  let value = obj.stringValue else { return }
            session.stopRunning()
            onCode?(value)
        }
    }
}
#endif
