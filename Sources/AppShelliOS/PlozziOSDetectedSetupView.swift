#if os(iOS)
import CoreModels
import CoreUI
import SwiftUI

/// Full-page "we found your setup" screen — the promoted, full-screen version of the
/// mid-session new-server drawer. Shown on a fresh launch ONLY when we detected
/// household servers that genuinely need bringing over (see
/// `PlozziOSAppModel.pendingServersNeedingSetup` — in practice Apple-TV-origin
/// servers, since iOS→iOS logins auto-connect silently and never reach here).
///
/// The app leads with what it already knows: instead of the plain provider chooser,
/// a returning user sees their own setup and one tap to bring it over. A quiet
/// "Set up manually" escape drops to the normal chooser. Adaptive: two columns when
/// wide (iPad landscape), stacked when narrow (iPhone / iPad portrait).
@MainActor
struct PlozziOSDetectedSetupView: View {
    @Environment(\.themePalette) private var palette
    @Environment(\.horizontalSizeClass) private var hSize
    let appModel: PlozziOSAppModel
    /// Bring everything over from the detected device (runs the receive/pairing flow,
    /// seamless on the same iCloud account).
    let onSetUpFromDevice: () -> Void
    /// Quiet escape to the normal provider chooser.
    let onSetUpManually: () -> Void

    private var servers: [SyncedAccountDescriptor] { appModel.pendingServersNeedingSetup }
    private var originName: String? { appModel.pendingSetupOriginName }

    /// SF Symbol for the origin device kind, matching the new-server drawer's mapping.
    private var originIcon: String {
        switch appModel.pendingSetupOriginKind {
        case "tv": return "appletv.fill"
        case "pad": return "ipad"
        case "phone": return "iphone"
        case "mac": return "desktopcomputer"
        default: return "display"
        }
    }

    private var isWide: Bool { hSize == .regular }

    var body: some View {
        ZStack {
            AppBackground(palette: palette)
            GeometryReader { geo in
                ScrollView {
                    Group {
                        if isWide {
                            HStack(alignment: .center, spacing: 64) {
                                branding
                                    .frame(maxWidth: .infinity)
                                card
                                    .frame(maxWidth: .infinity)
                            }
                            .frame(minHeight: geo.size.height)
                        } else {
                            VStack(spacing: 32) {
                                Spacer(minLength: geo.size.height * 0.06)
                                branding
                                card
                                Spacer(minLength: 24)
                            }
                            .frame(maxWidth: 500)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: geo.size.height)
                        }
                    }
                    .padding(.horizontal, isWide ? 56 : 24)
                }
            }
        }
    }

    private var branding: some View {
        VStack(spacing: 14) {
            Image("PlozzLogo")
                .resizable().scaledToFit()
                .frame(width: 88, height: 88)
            Image("PlozzWordmark")
                .resizable().scaledToFit()
                .frame(height: 38)
                .foregroundStyle(palette.primaryText)
            Text("Free forever and open source.")
                .font(.subheadline)
                .foregroundStyle(palette.secondaryText)
        }
    }

    private var card: some View {
        VStack(spacing: 0) {
            header

            VStack(spacing: 0) {
                ForEach(Array(servers.prefix(4)), id: \.id) { server in
                    serverRow(server)
                    if server.id != servers.prefix(4).last?.id { divider }
                }
                if servers.count > 4 {
                    divider
                    Text("+ \(servers.count - 4) more")
                        .font(.subheadline)
                        .foregroundStyle(palette.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                }
            }
            .background(palette.cardSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(palette.cardBorder, lineWidth: 1)
            )
            .padding(.top, 22)

            actions
                .padding(.top, 24)
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Text(servers.count == 1 ? "We found your server" : "We found your setup")
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
            subtitle
                .font(.subheadline)
                .foregroundStyle(palette.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private var subtitle: Text {
        if let originName {
            return Text("You’re already set up on \(Image(systemName: originIcon)) \(originName). Bring it here?")
        }
        return Text("You’re already set up on another device. Bring it here?")
    }

    private func serverRow(_ server: SyncedAccountDescriptor) -> some View {
        HStack(spacing: 14) {
            ProviderBrandMark(provider: server.provider, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.serverName)
                    .font(.headline)
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)
                Text(server.provider.displayName)
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var divider: some View {
        Rectangle().fill(palette.cardBorder).frame(height: 1)
            .padding(.horizontal, 1)
    }

    private var actions: some View {
        VStack(spacing: 12) {
            Button(action: onSetUpFromDevice) {
                Group {
                    if let originName {
                        Text("Set Up from \(Image(systemName: originIcon)) \(originName)")
                    } else {
                        Text("Set Up from Your Other Device")
                    }
                }
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            Button(action: onSetUpManually) {
                Text("Set up manually")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .controlSize(.large)
        .tint(palette.accent)
    }
}
#endif
