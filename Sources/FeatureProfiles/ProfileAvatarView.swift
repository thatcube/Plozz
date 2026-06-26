#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// Renders a profile's avatar at `size` pt. Prefers the opt-in real photo
/// (`Profile.avatarImageURL`) when present and reachable; otherwise falls
/// back to the SF Symbol on the colored tile (`avatarSymbol` + `colorIndex`).
///
/// Photos load through the shared `ArtworkImageCache` (via `FallbackAsyncImage`),
/// so an already-decoded avatar renders on the first frame with no flash, the
/// raw download is shared with the picker's background-color extraction, and a
/// re-opened picker shows photos instantly. While a photo is still loading it
/// shows a quiet neutral placeholder (not the colored symbol), so a photo
/// profile never briefly flashes a stand-in icon behind the photo. The symbol
/// fallback is reserved for symbol-only profiles and genuine load failures.
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
                FallbackAsyncImage(urls: [url], variant: Self.variant(for: size)) {
                    // Shown only when the photo genuinely fails to load — keeps the
                    // tile recognizable instead of an empty circle.
                    symbolFallback
                }
            } else {
                symbolFallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    /// Picks a cache variant sized to the avatar: a crisp source for the large
    /// picker tiles, a cheap thumbnail for the small Settings rows.
    private static func variant(for size: CGFloat) -> ArtworkImageVariant {
        size >= 160 ? .posterCard : .musicThumbnail
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
