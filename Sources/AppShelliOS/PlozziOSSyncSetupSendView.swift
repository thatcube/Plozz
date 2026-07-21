#if os(iOS)
import SwiftUI
import AVFoundation
import CoreModels
import CoreUI
import FeatureProfiles
import FeatureSyncSetup

// MARK: - Reusable pairing screens/components used by the Sync & Setup page.

/// Shared "the other device is set up" success screen, shown to the sender after a
/// successful pair. Uses the app's design language — provider logos + server names
/// and profile avatars + names — rather than a generic checkmark.
@MainActor
struct SyncSetupSentSuccessView: View {
    @Environment(\.themePalette) private var palette
    let accounts: [Account]
    let profiles: [Profile]
    let onDone: () -> Void

    private var servers: [Account] {
        var seen = Set<String>()
        return accounts.filter { seen.insert($0.server.id).inserted }
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 0)
            VStack(spacing: 8) {
                Text("Your other device is set up")
                    .font(.title2.bold()).multilineTextAlignment(.center)
                    .foregroundStyle(palette.primaryText)
            }
            .padding(.horizontal, 24)

            VStack(spacing: 14) {
                if !servers.isEmpty {
                    sectionCard(title: servers.count == 1 ? "Server" : "Servers") {
                        ForEach(servers) { account in
                            HStack(spacing: 14) {
                                ProviderBrandMark(provider: account.server.provider, size: 32)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(account.server.name)
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(palette.primaryText)
                                    Text("Signed in")
                                        .font(.caption).foregroundStyle(palette.secondaryText)
                                }
                                Spacer()
                            }
                        }
                    }
                }
                if !profiles.isEmpty {
                    sectionCard(title: profiles.count == 1 ? "Profile" : "Profiles") {
                        HStack(spacing: 18) {
                            ForEach(profiles, id: \.id) { profile in
                                VStack(spacing: 6) {
                                    ProfileAvatarView(profile: profile, size: 56)
                                    Text(profile.name)
                                        .font(.caption).foregroundStyle(palette.primaryText)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: 84)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)

            Spacer(minLength: 0)
            Button("Done", action: onDone)
                .syncPrimaryButtonStyle().controlSize(.large)
                .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func sectionCard<Content: View>(
        title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold)).tracking(1.2)
                .foregroundStyle(palette.secondaryText)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(palette.cardSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(palette.cardBorder, lineWidth: 1)
        )
    }
}

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
                    .syncPrimaryButtonStyle()
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
