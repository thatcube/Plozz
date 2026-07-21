#if os(iOS)
import SwiftUI
import CoreUI
import FeatureSyncSetup

/// Numeric-comparison (SAS) confirmation shown on the SENDER during a non-QR pair
/// (tap-to-pair, typed code, or universal link). The user checks the same number
/// appears on the other device before any credentials are trusted — this defeats a
/// man-in-the-middle on the cameraless paths. Confirming drives `confirmSASMatch`.
@MainActor
struct SyncSetupSASConfirmView: View {
    @Environment(\.themePalette) private var palette
    let code: String
    let onResult: (Bool) -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 0)
            Image(systemName: "checkmark.shield")
                .font(.system(size: 44)).foregroundStyle(palette.accent)
            Text("Does this code match?")
                .font(.title2.bold()).foregroundStyle(palette.primaryText)
            Text(SyncPairingSAS.grouped(code))
                .font(.system(size: 56, weight: .bold, design: .rounded)).monospaced()
                .foregroundStyle(palette.primaryText)
            Text("Check the same number shows on the device you're setting up, then confirm.")
                .font(.callout).foregroundStyle(palette.secondaryText)
                .multilineTextAlignment(.center).padding(.horizontal, 24)
            Spacer(minLength: 0)
            VStack(spacing: 12) {
                Button("Yes, they match") { onResult(true) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                Button("No, they're different", role: .cancel) { onResult(false) }
            }
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif
