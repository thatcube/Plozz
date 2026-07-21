#if os(iOS)
import CoreImage.CIFilterBuiltins
import CoreModels
import CoreUI
import FeatureProfiles
import FeatureSyncSetup
import SwiftUI
import UIKit

/// iOS/iPadOS "Set up this device from another" screen: this device advertises and
/// shows a QR + short code. A device that's already signed in (another phone/tablet
/// or an Apple TV) scans/enters it and transfers servers + profiles, so this device
/// is signed in with no typing.
@MainActor
struct PlozziOSSyncSetupReceiveView: View {
    @Environment(\.themePalette) private var palette
    let appModel: PlozziOSAppModel
    let onClose: () -> Void
    @State private var model: SyncSetupPairingModel
    @State private var didApply = false
    @State private var applyError: String?

    init(appModel: PlozziOSAppModel, onClose: @escaping () -> Void) {
        self.appModel = appModel
        self.onClose = onClose
        _model = State(initialValue: SyncSetupPairingModel(service: appModel.syncSetup))
    }

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
                .navigationTitle("Set Up This Device")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        if case .applied = model.phase { EmptyView() } else {
                            Button("Cancel", action: onClose)
                        }
                    }
                }
                .alert("Setup didn’t finish", isPresented: Binding(
                    get: { applyError != nil }, set: { if !$0 { applyError = nil } }
                )) {
                    Button("OK", role: .cancel) {}
                } message: { Text(applyError ?? "") }
        }
        .task { await model.startReceiving() }
        .onDisappear { model.stopReceiving() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .waitingForPeer(let code, let invite):
            waiting(code: code, invite: invite)
        case .applying:
            if let sas = model.hostSASCode {
                sasCompare(sas)
            } else {
                centered {
                    ProgressView().controlSize(.large)
                    Text("Setting up…").font(.headline).foregroundStyle(palette.secondaryText)
                }
            }
        case .applied(let received):
            appliedSummary(received)
        case .failed(let message):
            centered {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 54)).foregroundStyle(palette.secondaryText)
                Text("Setup didn’t finish").font(.title3.bold())
                Text(message).foregroundStyle(palette.secondaryText)
                    .multilineTextAlignment(.center)
                Button("Try Again") { Task { await model.startReceiving() } }
                    .syncPrimaryButtonStyle()
            }
        default:
            centered { ProgressView() }
        }
    }

    private func waiting(code: String, invite: SyncPairingInvite) -> some View {
        VStack(spacing: 24) {
            Spacer(minLength: 0)
            Text("Set up this device from another")
                .font(.title2.bold()).multilineTextAlignment(.center)
                .foregroundStyle(palette.primaryText)
            if let img = Self.qrImage(invite.encoded()) {
                Image(uiImage: img).interpolation(.none).resizable()
                    .frame(width: 220, height: 220)
                    .padding(16).background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            VStack(spacing: 6) {
                Text("or enter this code").font(.callout).foregroundStyle(palette.secondaryText)
                Text(SyncPairingCode.grouped(code))
                    .font(.system(size: 40, weight: .bold, design: .rounded)).monospaced()
                    .foregroundStyle(palette.primaryText)
            }
            Text("On a device that’s already signed in, open Plozz ▸ Settings ▸ Sync & Setup ▸ “Set up another device,” then scan this code. Both devices must be on the same Wi-Fi.")
                .font(.footnote).foregroundStyle(palette.secondaryText)
                .multilineTextAlignment(.center).padding(.horizontal, 12)
            Spacer(minLength: 0)
        }
    }

    // MARK: Verification code (SAS) — the receiver shows the number so the user can
    // confirm it matches the sending device before trusting the transfer.

    private func sasCompare(_ code: String) -> some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            Image(systemName: "checkmark.shield")
                .font(.system(size: 44)).foregroundStyle(palette.accent)
            Text("Check this code").font(.title2.bold())
                .foregroundStyle(palette.primaryText)
            Text(SyncPairingSAS.grouped(code))
                .font(.system(size: 56, weight: .bold, design: .rounded)).monospaced()
                .foregroundStyle(palette.primaryText)
            Text("Make sure the same number shows on your other device, then confirm there.")
                .font(.callout).foregroundStyle(palette.secondaryText)
                .multilineTextAlignment(.center).padding(.horizontal, 24)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Applied summary (received servers + profiles, on-brand)

    @ViewBuilder
    private func appliedSummary(_ received: SyncSetupService.ReceivedSetup) -> some View {
        let authIDs = Set(received.application.authorizedAuthorizations.map(\.id))
        let servers = received.config.accounts.filter { authIDs.contains($0.id) }
        let profiles = received.config.profiles.map(\.profile)

        VStack(spacing: 22) {
            Spacer(minLength: 0)
            VStack(spacing: 8) {
                Text("You’re all set").font(.title.bold()).foregroundStyle(palette.primaryText)
            }
            VStack(spacing: 14) {
                if !servers.isEmpty {
                    card(title: servers.count == 1 ? "Server" : "Servers") {
                        ForEach(servers) { server in
                            HStack(spacing: 14) {
                                ProviderBrandMark(provider: server.provider, size: 32)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(server.serverName).font(.body.weight(.semibold))
                                        .foregroundStyle(palette.primaryText)
                                    Text("Signed in").font(.caption)
                                        .foregroundStyle(palette.secondaryText)
                                }
                                Spacer()
                            }
                        }
                    }
                }
                if !profiles.isEmpty {
                    card(title: profiles.count == 1 ? "Profile" : "Profiles") {
                        HStack(spacing: 18) {
                            ForEach(profiles, id: \.id) { profile in
                                VStack(spacing: 6) {
                                    ProfileAvatarView(profile: profile, size: 56)
                                    Text(profile.name).font(.caption)
                                        .foregroundStyle(palette.primaryText).lineLimit(1)
                                }
                                .frame(maxWidth: 84)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            Button("Start Watching") {
                guard !didApply else { return }
                didApply = true
                let outcome = appModel.applyReceivedSetup(received)
                if outcome.isTotalCredentialFailure {
                    didApply = false   // allow a retry
                    applyError = "Couldn’t finish signing in on this device. Check both devices are on the same Wi-Fi and try again."
                } else {
                    onClose()
                }
            }
            .syncPrimaryButtonStyle().controlSize(.large)
        }
    }

    @ViewBuilder
    private func card<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).tracking(1.2)
                .foregroundStyle(palette.secondaryText)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(palette.cardSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(palette.cardBorder, lineWidth: 1))
    }

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 16) { content() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static func qrImage(_ string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?
            .transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
        let context = CIContext()
        guard let cg = context.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
#endif
