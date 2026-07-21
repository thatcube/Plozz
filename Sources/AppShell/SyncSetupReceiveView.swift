#if os(tvOS)
import SwiftUI
import CoreImage.CIFilterBuiltins
import CoreModels
import CoreUI
import FeatureProfiles
import FeatureSyncSetup

/// tvOS "Set up from another device" screen: shows a QR + short code, advertises
/// over the local network, receives the sealed setup, and persists it so the TV is
/// signed in with no typing.
@MainActor
struct SyncSetupReceiveView: View {
    @Environment(\.themePalette) private var palette
    private let appState: AppState
    private let onClose: () -> Void
    @State private var model: SyncSetupPairingModel
    @State private var didApply = false
    @State private var applyError: String?

    init(appState: AppState, onClose: @escaping () -> Void) {
        self.appState = appState
        self.onClose = onClose
        _model = State(initialValue: SyncSetupPairingModel(service: appState.syncSetup))
    }

    var body: some View {
        ZStack {
            AppBackground(palette: palette)
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await model.startReceiving() }
        .onDisappear { model.stopReceiving() }
        .alert("Setup didn’t finish", isPresented: Binding(
            get: { applyError != nil }, set: { if !$0 { applyError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: { Text(applyError ?? "") }
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 28) {
            switch model.phase {
            case .idle:
                ProgressView()
            case .waitingForPeer(let code, let invite):
                Text("Set up from another device").font(.largeTitle.bold())
                    .foregroundStyle(palette.primaryText)
                HStack(alignment: .center, spacing: 60) {
                    if let img = Self.qrImage(invite.encoded()) {
                        VStack(spacing: 12) {
                            Image(uiImage: img).interpolation(.none).resizable()
                                .frame(width: 340, height: 340)
                                .padding(18).background(.white).cornerRadius(16)
                            Text("Scan with your phone or tablet").font(.callout)
                                .foregroundStyle(palette.secondaryText)
                        }
                    }
                    VStack(spacing: 10) {
                        Text("or enter code").font(.callout).foregroundStyle(palette.secondaryText)
                        Text(SyncPairingCode.grouped(code))
                            .font(.system(size: 56, weight: .bold, design: .rounded)).monospaced()
                            .foregroundStyle(palette.primaryText)
                        Text("on another device").font(.callout).foregroundStyle(palette.secondaryText)
                    }
                }
                Text("On your other device, open Plozz ▸ Settings ▸ Sync & Setup ▸ “Set up another device.”")
                    .font(.headline).foregroundStyle(palette.secondaryText)
                    .multilineTextAlignment(.center).frame(maxWidth: 900)
            case .applying:
                if let sas = model.hostSASCode {
                    sasComparison(sas)
                } else {
                    ProgressView("Setting up…").font(.title2).foregroundStyle(palette.primaryText)
                }
            case .confirmingSAS(let sas):
                sasComparison(sas)
            case .applied(let received):
                appliedSummary(received)
            case .connecting, .sending, .sent:
                ProgressView()
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle").font(.system(size: 60))
                    .foregroundStyle(palette.secondaryText)
                Text(message).foregroundStyle(palette.secondaryText).multilineTextAlignment(.center)
                Button("Try Again") { Task { await model.startReceiving() } }
            }

            if case .applied = model.phase {} else {
                Button("Cancel", role: .cancel) { onClose() }.padding(.top, 12)
            }
        }
        .padding(70)
    }

    // MARK: Verification code (SAS) — shown so the user can confirm both devices
    // display the SAME number before any credentials are trusted.

    @ViewBuilder
    private func sasComparison(_ code: String) -> some View {
        VStack(spacing: 24) {
            Text("Check this code").font(.largeTitle.bold())
                .foregroundStyle(palette.primaryText)
            Text(SyncPairingSAS.grouped(code))
                .font(.system(size: 84, weight: .bold, design: .rounded)).monospaced()
                .foregroundStyle(palette.primaryText)
            Text("Make sure the same number shows on your other device, then confirm there.")
                .font(.headline).foregroundStyle(palette.secondaryText)
                .multilineTextAlignment(.center).frame(maxWidth: 900)
        }
    }

    // MARK: Applied summary (app design language — provider logos + profiles)

    @ViewBuilder
    private func appliedSummary(_ received: SyncSetupService.ReceivedSetup) -> some View {
        let authIDs = Set(received.application.authorizedAuthorizations.map(\.id))
        let servers = received.config.accounts.filter { authIDs.contains($0.id) }
        let profiles = received.config.profiles.map(\.profile)

        VStack(spacing: 44) {
            VStack(spacing: 12) {
                Text("You’re all set")
                    .font(.largeTitle.bold()).foregroundStyle(palette.primaryText)
            }

            HStack(alignment: .top, spacing: 56) {
                if !servers.isEmpty {
                    summarySection(title: servers.count == 1 ? "Server" : "Servers") {
                        VStack(alignment: .leading, spacing: 18) {
                            ForEach(servers) { server in
                                HStack(spacing: 18) {
                                    ProviderBrandMark(provider: server.provider, size: 44)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(server.serverName)
                                            .font(.title3.weight(.semibold))
                                            .foregroundStyle(palette.primaryText)
                                        Text("Signed in")
                                            .font(.callout).foregroundStyle(palette.secondaryText)
                                    }
                                }
                            }
                        }
                    }
                }
                if !profiles.isEmpty {
                    summarySection(title: profiles.count == 1 ? "Profile" : "Profiles") {
                        HStack(alignment: .top, spacing: 28) {
                            ForEach(profiles, id: \.id) { profile in
                                VStack(spacing: 10) {
                                    ProfileAvatarView(profile: profile, size: 96)
                                    Text(profile.name)
                                        .font(.callout).foregroundStyle(palette.primaryText)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: 140)
                            }
                        }
                    }
                }
            }

            Button("Start Watching") {
                guard !didApply else { return }
                didApply = true
                let outcome = appState.applyReceivedSetup(received)
                if outcome.isTotalCredentialFailure {
                    didApply = false   // allow a retry
                    applyError = "Couldn’t finish signing in on this Apple TV. Check both devices are on the same Wi-Fi and try again."
                } else {
                    onClose()
                }
            }
            .font(.title3.weight(.semibold))
        }
    }

    @ViewBuilder
    private func summarySection<Content: View>(
        title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold)).tracking(1.5)
                .foregroundStyle(palette.secondaryText)
            content()
        }
        .padding(28)
        .background(palette.cardSurface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(palette.cardBorder, lineWidth: 1)
        )
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
