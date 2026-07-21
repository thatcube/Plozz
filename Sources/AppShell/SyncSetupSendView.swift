#if os(tvOS)
import CoreModels
import CoreUI
import FeatureProfiles
import FeatureSyncSetup
import SwiftUI

/// tvOS "Set up another device" (sender) screen. The Apple TV has no camera, so it
/// browses for nearby devices that are waiting to be set up and lets you pick one
/// (tap-to-pair), with an on-screen code field as a fallback. Credentials then flow
/// from this Apple TV to the chosen device over the E2E-encrypted pairing channel.
@MainActor
struct SyncSetupSendView: View {
    @Environment(\.themePalette) private var palette
    private let appState: AppState
    private let onClose: () -> Void
    @State private var model: SyncSetupPairingModel
    @State private var code = ""
    @State private var handled = false

    init(appState: AppState, onClose: @escaping () -> Void) {
        self.appState = appState
        self.onClose = onClose
        _model = State(initialValue: SyncSetupPairingModel(service: appState.syncSetup))
    }

    var body: some View {
        ZStack {
            AppBackground(palette: palette)
            content.frame(maxWidth: .infinity, maxHeight: .infinity).padding(70)
        }
        .onAppear { model.startDiscovery() }
        .onDisappear { model.stopDiscovery() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle:
            picker
        case .connecting, .sending:
            VStack(spacing: 18) {
                ProgressView().controlSize(.large)
                Text("Setting up the other device…").font(.title2)
                    .foregroundStyle(palette.secondaryText)
            }
        case .sent:
            sentSummary
        case .confirmingSAS(let sas):
            sasConfirm(sas)
        case .failed(let message):
            VStack(spacing: 18) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 60))
                    .foregroundStyle(palette.secondaryText)
                Text("Setup didn’t finish").font(.title2.bold())
                Text(message).foregroundStyle(palette.secondaryText).multilineTextAlignment(.center)
                Button("Try Again") { handled = false; model.reset(); model.startDiscovery() }
                Button("Cancel", role: .cancel) { onClose() }
            }
        default:
            ProgressView()
        }
    }

    // MARK: Picker (nearby + code)

    private var picker: some View {
        VStack(spacing: 40) {
            VStack(spacing: 10) {
                Text("Set up another device").font(.largeTitle.bold())
                    .foregroundStyle(palette.primaryText)
                Text("On the device you want to set up, open Plozz and choose “Set up from another device.” It’ll appear here.")
                    .font(.title3).foregroundStyle(palette.secondaryText)
                    .multilineTextAlignment(.center).frame(maxWidth: 1000)
            }

            HStack(alignment: .top, spacing: 48) {
                nearbyColumn
                codeColumn
            }

            Button("Cancel", role: .cancel) { onClose() }.padding(.top, 8)
        }
    }

    private var nearbyColumn: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("NEARBY").font(.caption.weight(.semibold)).tracking(1.5)
                .foregroundStyle(palette.secondaryText)
            if model.nearbyDevices.isEmpty {
                HStack(spacing: 14) {
                    ProgressView()
                    Text("Looking for a device…").foregroundStyle(palette.secondaryText)
                }
                .frame(width: 460, alignment: .leading)
            } else {
                ForEach(model.nearbyDevices) { device in
                    Button {
                        guard !handled else { return }
                        handled = true
                        Task { await model.pair(with: device) }
                    } label: {
                        HStack(spacing: 16) {
                            Image(systemName: "iphone").font(.title2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.displayName).font(.title3.weight(.semibold))
                                Text("Code \(SyncPairingCode.grouped(device.serviceName))")
                                    .font(.callout).foregroundStyle(palette.secondaryText)
                            }
                            Spacer()
                        }
                        .frame(width: 460)
                    }
                }
            }
        }
    }

    private var codeColumn: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("OR ENTER CODE").font(.caption.weight(.semibold)).tracking(1.5)
                .foregroundStyle(palette.secondaryText)
            TextField("Code", text: $code)
                .textInputAutocapitalization(.characters)
                .disableAutocorrection(true)
                .frame(width: 300)
            Button("Set Up") {
                guard !handled else { return }
                handled = true
                Task { await model.send(code: code) }
            }
            .disabled(SyncPairingCode.normalize(code).count < 4)
        }
    }

    // MARK: Verification code (SAS) confirmation — the sender gates the transfer
    // on the user confirming both devices show the SAME number, defeating a
    // man-in-the-middle on the (cameraless) tap-to-pair / code paths.

    @ViewBuilder
    private func sasConfirm(_ code: String) -> some View {
        VStack(spacing: 28) {
            Text("Does this code match?").font(.largeTitle.bold())
                .foregroundStyle(palette.primaryText)
            Text(SyncPairingSAS.grouped(code))
                .font(.system(size: 84, weight: .bold, design: .rounded)).monospaced()
                .foregroundStyle(palette.primaryText)
            Text("Check the other device shows the same number before continuing.")
                .font(.headline).foregroundStyle(palette.secondaryText)
                .multilineTextAlignment(.center).frame(maxWidth: 900)
            HStack(spacing: 24) {
                Button("Yes, they match") { model.confirmSASMatch(true) }
                    .font(.title3.weight(.semibold))
                Button("No", role: .cancel) { model.confirmSASMatch(false) }
                    .font(.title3)
            }
            .padding(.top, 8)
        }
    }

    // MARK: Sent success (what this Apple TV sent)

    private var sentSummary: some View {
        let servers = uniqueServers(appState.accountsProviders.accounts)
        let profiles = appState.profilesModel.profiles
        return VStack(spacing: 40) {
            VStack(spacing: 12) {
                Text("The other device is set up").font(.largeTitle.bold())
                    .foregroundStyle(palette.primaryText)
            }
            HStack(alignment: .top, spacing: 56) {
                if !servers.isEmpty {
                    section(title: servers.count == 1 ? "Server" : "Servers") {
                        VStack(alignment: .leading, spacing: 18) {
                            ForEach(servers, id: \.id) { account in
                                HStack(spacing: 18) {
                                    ProviderBrandMark(provider: account.server.provider, size: 44)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(account.server.name).font(.title3.weight(.semibold))
                                            .foregroundStyle(palette.primaryText)
                                        Text("Signed in").font(.callout)
                                            .foregroundStyle(palette.secondaryText)
                                    }
                                }
                            }
                        }
                    }
                }
                if !profiles.isEmpty {
                    section(title: profiles.count == 1 ? "Profile" : "Profiles") {
                        HStack(alignment: .top, spacing: 28) {
                            ForEach(profiles, id: \.id) { profile in
                                VStack(spacing: 10) {
                                    ProfileAvatarView(profile: profile, size: 96)
                                    Text(profile.name).font(.callout)
                                        .foregroundStyle(palette.primaryText).lineLimit(1)
                                }
                                .frame(maxWidth: 140)
                            }
                        }
                    }
                }
            }
            Button("Done") { onClose() }.font(.title3.weight(.semibold))
        }
    }

    private func uniqueServers(_ accounts: [Account]) -> [Account] {
        var seen = Set<String>()
        return accounts.filter { seen.insert($0.server.id).inserted }
    }

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).tracking(1.5)
                .foregroundStyle(palette.secondaryText)
            content()
        }
        .padding(28)
        .background(palette.cardSurface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(palette.cardBorder, lineWidth: 1))
    }
}
#endif
