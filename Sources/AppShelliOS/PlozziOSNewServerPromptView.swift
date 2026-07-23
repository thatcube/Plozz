#if os(iOS)
import CoreModels
import CoreUI
import SwiftUI

/// A friendly bottom-sheet card shown once when a server added on another device
/// (e.g. the Apple TV) syncs here. Replaces the plain system alert so we can show the
/// real provider logo, a short headline, and clearly-ranked actions.
///
/// Two ways to add it: sign in here (opens Add Server pre-filled), or pull the login
/// from the other device with no typing (the pairing flow). "Not Now" just dismisses —
/// the server still shows under Settings ▸ iCloud Sync.
struct PlozziOSNewServerPromptView: View {
    let descriptor: SyncedAccountDescriptor
    let accent: Color
    let onSignIn: () -> Void
    let onUseOtherDevice: () -> Void
    let onNotNow: () -> Void

    /// The friendly origin device name ("Brando's TV"), when the publisher stamped one.
    private var originName: String? {
        let n = descriptor.originDeviceName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (n?.isEmpty ?? true) ? nil : n
    }

    /// SF Symbol for the origin device kind, defaulting to a generic device.
    private var originIcon: String {
        switch descriptor.originDeviceKind {
        case "tv": return "appletv.fill"
        case "pad": return "ipad"
        case "phone": return "iphone"
        case "mac": return "desktopcomputer"
        default: return "display"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                ProviderBrandMark(provider: descriptor.provider, size: 76)
                // Badge the origin device kind on the provider logo, when known.
                if originName != nil {
                    Image(systemName: originIcon)
                        .font(.system(size: 22))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(accent)
                        .padding(6)
                        .background(.background, in: Circle())
                        .offset(x: 8, y: 6)
                }
            }
            .padding(.top, 32)

            Text("Add “\(descriptor.serverName)”?")
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
                .padding(.top, 18)
                .padding(.horizontal, 24)

            Text(originName.map { "It’s ready on \($0). Add it here to start watching." }
                 ?? "It’s ready on your other device. Add it here to start watching.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
                .padding(.horizontal, 28)

            VStack(spacing: 12) {
                Button(action: onSignIn) {
                    Text("Sign In Here")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button(action: onUseOtherDevice) {
                    Text(originName.map { "Set Up With \($0)" } ?? "Set Up With Other Device")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button("Not Now", action: onNotNow)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            .controlSize(.large)
            .tint(accent)
            .padding(.top, 28)
            .padding(.horizontal, 24)

            Spacer(minLength: 0)
        }
        .padding(.bottom, 24)
        .presentationDetents([.height(440)])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
    }
}
#endif
