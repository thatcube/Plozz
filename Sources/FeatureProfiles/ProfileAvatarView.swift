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
                    emojiOrSymbolFallback
                }
            } else {
                emojiOrSymbolFallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    /// Emoji (if chosen) else the symbol tile. Used both as the primary
    /// non-photo avatar and as the fallback when a borrowed photo URL fails.
    @ViewBuilder
    private var emojiOrSymbolFallback: some View {
        if let emoji = profile.avatarEmoji?.trimmingCharacters(in: .whitespaces),
           !emoji.isEmpty {
            emojiTile(emoji)
        } else {
            symbolFallback
        }
    }

    /// Native Apple emoji rendered as text. By default it sits on a
    /// theme-neutral disc (colours often clash with a multicolour emoji), but a
    /// profile may opt into a palette colour via `avatarEmojiColorIndex` — so the
    /// background is the chosen colour when set, otherwise a neutral surface.
    private func emojiTile(_ emoji: String) -> some View {
        ZStack {
            if let index = profile.avatarEmojiColorIndex {
                Circle().fill(ProfileTileColor.color(forIndex: index))
            } else {
                Circle().fill(Self.neutralEmojiBackground)
            }
            Text(emoji)
                .font(.system(size: size * 0.55))
                .minimumScaleFactor(0.5)
        }
    }

    /// Theme-aware neutral disc behind an emoji avatar: a muted grey that reads
    /// on both light and dark themes without competing with the emoji's own
    /// colours.
    private static var neutralEmojiBackground: Color {
        Color.gray.opacity(0.35)
    }

    /// Picks a cache variant sized to the avatar: a crisp source for the large
    /// picker tiles, a cheap thumbnail for the small Settings rows.
    private static func variant(for size: CGFloat) -> ArtworkImageVariant {
        size >= 160 ? .posterCard : .musicThumbnail
    }

    /// Symbol on colored tile — the original avatar style. Also used as the
    /// fallback when a borrowed photo URL fails to load. The glyph colour adapts
    /// to the tile so it stays legible on light backgrounds (e.g. a white or
    /// yellow tile gets a dark glyph instead of an invisible white one).
    private var symbolFallback: some View {
        ZStack {
            Circle().fill(ProfileTileColor.color(for: profile))
            Image(systemName: profile.avatarSymbol)
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(ProfileTileColor.legibleForeground(for: profile))
        }
    }
}
#endif
