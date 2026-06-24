#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// Renders a profile's avatar at `size` pt. Prefers the opt-in real photo
/// (`Profile.avatarImageURL`) when present and reachable; otherwise falls
/// back to the SF Symbol on the colored tile (`avatarSymbol` + `colorIndex`).
///
/// A stale or broken URL never yields an empty circle — `AsyncImage`'s
/// failure phase reuses the symbol fallback so the picker tile and Settings
/// hero always show *something* recognizable.
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
                AsyncImage(url: url) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().scaledToFill()
                    case .empty, .failure:
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
