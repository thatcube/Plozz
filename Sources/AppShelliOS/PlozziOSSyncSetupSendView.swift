#if os(iOS)
import SwiftUI
import AVFoundation
import FeatureSyncSetup

// MARK: - Reusable pairing screens/components used by the Sync & Setup page.

/// Full-screen QR scanner screen (camera needs the full screen).
@MainActor
struct SyncSetupScannerScreen: View {
    let onCode: (String) -> Void
    let onCancel: () -> Void
    var body: some View {
        ZStack {
            QRScannerView(onCode: onCode).ignoresSafeArea()
            VStack {
                HStack { Spacer(); Button("Cancel") { onCancel() }.padding().foregroundStyle(.white) }
                Spacer()
                Text("Point your camera at the code on your other device — pinch to zoom")
                    .font(.headline).padding()
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 60)
            }
        }
    }
}

/// Manual code-entry sheet.
@MainActor
struct SyncSetupCodeEntryScreen: View {
    @State private var typedCode = ""
    let onSubmit: (String) -> Void
    let onCancel: () -> Void
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "keyboard").font(.system(size: 48)).foregroundStyle(.tint)
                Text("Enter the code shown on your other device").font(.headline).multilineTextAlignment(.center)
                TextField("Code", text: $typedCode)
                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
                    .multilineTextAlignment(.center)
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .textFieldStyle(.roundedBorder).padding(.horizontal, 40)
                Button("Continue") { onSubmit(typedCode) }
                    .buttonStyle(.borderedProminent)
                    .disabled(SyncPairingCode.normalize(typedCode).count < 4)
                Spacer()
            }
            .padding(.top, 60)
            .navigationTitle("Enter Code").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { onCancel() } } }
        }
    }
}

/// Minimal AVFoundation QR scanner with pinch-to-zoom.
struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerVC {
        let vc = ScannerVC(); vc.onCode = onCode; return vc
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
