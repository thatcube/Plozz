#if canImport(SwiftUI)
import SwiftUI

/// The standardised header for onboarding / account-setup screens (Quick
/// Connect, password sign-in, Plex user picker, library picker, add-share).
///
/// Before this existed each screen hand-rolled its own title, and they'd drifted
/// apart — some used a huge `.largeTitle`, others `.title`, with `.title3` vs
/// `.subheadline` subtitles. This pins them all to one scale: a `.title2`-weight
/// title (about half the old `.largeTitle`) over a `.subheadline` subtitle, so
/// every setup screen reads the same.
public struct OnboardingHeader: View {
    private let title: LocalizedStringKey
    private let subtitle: LocalizedStringKey?

    public init(_ title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    public var body: some View {
        VStack(spacing: PlozzTheme.Spacing.xSmall) {
            Text(title)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)

            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 720)
            }
        }
    }
}
#endif
