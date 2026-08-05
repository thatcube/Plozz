#if canImport(SwiftUI)
import CoreModels
import CoreUI
import SwiftUI

/// Full-page lock offer shown as the last step of new-profile setup.
///
/// This belongs in the flow, not in an alert over Home. At this point the app has
/// already switched to the new profile, so dismissing the theme screen exposed
/// Home and then floated an onboarding question over unrelated content. Keeping
/// the offer full-screen preserves the sequence: libraries, theme, lock, Home.
///
/// The offer and PIN setup live in ONE cover. Presenting a second cover from the
/// first one's action is unreliable in SwiftUI, and briefly showing Home between
/// them makes the two screens feel unrelated.
public struct ProfileLockOfferView: View {
    private let profile: Profile
    private let syncEnabled: Bool
    private let validatePlexPIN: (String) async -> PlexPINValidationResult
    private let onComplete: (ProfileLock) -> Void
    private let onSkip: () -> Void

    @Environment(\.themePalette) private var palette
    @State private var isChoosingPIN = false

    public init(
        profile: Profile,
        syncEnabled: Bool,
        validatePlexPIN: @escaping (String) async -> PlexPINValidationResult = {
            _ in .unavailable
        },
        onComplete: @escaping (ProfileLock) -> Void,
        onSkip: @escaping () -> Void
    ) {
        self.profile = profile
        self.syncEnabled = syncEnabled
        self.validatePlexPIN = validatePlexPIN
        self.onComplete = onComplete
        self.onSkip = onSkip
    }

    public var body: some View {
        ZStack {
            AppBackground(palette: palette).ignoresSafeArea()
            if isChoosingPIN {
                ProfileLockSetupView(
                    profile: profile,
                    offersPlexPINReuse: profile.playsAsPINProtectedPlexUser,
                    syncEnabled: syncEnabled,
                    validatePlexPIN: validatePlexPIN,
                    onComplete: onComplete,
                    // Backing out of the keypad returns to the offer rather than
                    // ending setup, so a mistaken tap is not a dead end.
                    onCancel: { isChoosingPIN = false }
                )
            } else {
                offer
            }
        }
        .environment(\.colorScheme, palette.isLight ? .light : .dark)
    }

    private var offer: some View {
        VStack(spacing: 36) {
            Spacer()

            ProfileAvatarView(profile: profile, size: avatarSize)

            VStack(spacing: 14) {
                Text(ProfileLockCopy.offerTitle)
                    .font(.largeTitle.bold())
                    .foregroundStyle(palette.primaryText)
                    .multilineTextAlignment(.center)

                Text(ProfileLockCopy.offerMessage)
                    .font(.title3)
                    .foregroundStyle(palette.secondaryText)
                    .multilineTextAlignment(.center)

                if profile.isKids {
                    Text(ProfileLockCopy.offerMessageKids)
                        .font(.callout)
                        .foregroundStyle(palette.secondaryText)
                        .multilineTextAlignment(.center)
                }
            }

            Spacer()

            HStack(spacing: 24) {
                Button("No PIN", action: onSkip)
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                Button {
                    isChoosingPIN = true
                } label: {
                    Text(ProfileLockCopy.create)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 40)
        .padding(.vertical, 60)
    }

    private var avatarSize: CGFloat {
        #if os(tvOS)
        190
        #else
        128
        #endif
    }
}
#endif
