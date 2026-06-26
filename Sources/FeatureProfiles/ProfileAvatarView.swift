#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// Renders a profile's avatar at `size` pt. Prefers the opt-in real photo
/// (`Profile.avatarImageURL`) when present and reachable; otherwise falls
/// back to the SF Symbol on the colored tile (`avatarSymbol` + `colorIndex`).
///
/// While a photo is loading it shows a quiet neutral placeholder (not the
/// colored symbol), so a photo profile never briefly flashes a stand-in icon
/// behind the photo. The symbol fallback is reserved for symbol-only profiles
/// and genuine load failures, so a stale or broken URL still yields something
/// recognizable rather than an empty circle.
public struct ProfileAvatarView: View {
    public let profile: Profile
    public let size: CGFloat

    public init(profile: Profile, size: CGFloat) {
        self.profile = profile
        self.size = size
    }

    public var body: some View {
        Group {
            if let urlString = profile.avatarImageURL?.trimmingCharacters(in: .whitespaces),
               !urlString.isEmpty,
               let url = URL(string: urlString) {
                // Animate phase changes so the photo gently crossfades in over a
                // neutral placeholder — never flashing the colored symbol tile
                // underneath while the photo is still downloading.
                AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.35))) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().scaledToFill()
                            .transition(.opacity)
                    case .empty:
                        // Still loading: a quiet, adaptive placeholder — NOT the
                        // colored symbol — so a photo profile never momentarily
                        // shows a stand-in icon.
                        loadingPlaceholder
                    case .failure:
                        // The photo genuinely failed: fall back to the symbol so
                        // the tile still shows something recognizable.
                        symbolFallback
                    @unknown default:
                        symbolFallback
                    }
                }
            } else {
                symbolFallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    /// A neutral, theme-adaptive circle shown while a photo is loading. Keeps the
    /// avatar slot calm and consistent instead of flashing the colored symbol.
    private var loadingPlaceholder: some View {
        Circle().fill(.quaternary)
    }

    /// Symbol on colored tile — the original avatar style. Also used as the
    /// fallback when a borrowed photo URL fails to load.
    private var symbolFallback: some View {
        ZStack {
            Circle().fill(ProfileTileColor.color(for: profile))
            Image(systemName: profile.avatarSymbol)
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(.white)
        }
    }
}
#endif
