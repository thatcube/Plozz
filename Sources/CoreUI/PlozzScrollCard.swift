#if canImport(SwiftUI)
import SwiftUI

/// A rounded, translucent "card" wrapper for a **scrollable** area — the same
/// visual treatment as the Settings `SettingsPanel` (ultra-thin material fill +
/// hairline border + continuous 28pt corners), but sized to hold a `ScrollView`
/// that clips its content inside the card.
///
/// Onboarding screens (server picker, Plex-user picker, library picker) share a
/// pinned-header / scrolling-middle / pinned-footer layout; wrapping the middle
/// in this card makes the scroll region read as one contained surface, matching
/// Settings. Give the scroll content its own inner padding so the row focus fill
/// (which bleeds ~16pt outward) and its shadow are never clipped by the card.
public struct PlozzScrollCard<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .background(
                RoundedRectangle(cornerRadius: PlozzTheme.Metrics.mediumCardCornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: PlozzTheme.Metrics.mediumCardCornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: PlozzTheme.Metrics.mediumCardCornerRadius, style: .continuous))
    }
}
#endif
