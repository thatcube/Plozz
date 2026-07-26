#if canImport(SwiftUI)
import SwiftUI

/// The neutral stand-in for media artwork that is missing or failed to load.
///
/// One definition so a card without a poster looks the same on tvOS, iOS and
/// iPadOS. Before this existed each surface rolled its own: the tvOS cards drew
/// a glyph *and* repeated the title, while the iOS episode rows drew a bare
/// filled rectangle with no glyph at all.
///
/// Deliberately glyph-only. Every surface that uses this already prints the
/// item's title as a caption directly beneath the artwork, and that caption is
/// the better copy — it truncates to the card's width, follows Dynamic Type, and
/// carries the subtitle line. Repeating the title inside the artwork said the
/// same thing twice, a few points apart.
///
/// Marked decorative so VoiceOver reads the card's real label instead of
/// announcing an image.
public struct MediaArtworkPlaceholder: View {
    private let tint: Color
    private let glyphSize: CGFloat

    /// - Parameters:
    ///   - tint: colour the wash and glyph derive from. Defaults to `.secondary`
    ///     so the placeholder tracks the theme; pass an explicit colour where the
    ///     backdrop isn't theme-controlled (e.g. over video).
    ///   - glyphSize: point size of the play glyph, so a small episode thumbnail
    ///     and a full poster stay visually proportionate.
    public init(tint: Color = .secondary, glyphSize: CGFloat = 40) {
        self.tint = tint
        self.glyphSize = glyphSize
    }

    public var body: some View {
        ZStack {
            tint.opacity(0.08)
            Image(systemName: "play.rectangle")
                .font(.system(size: glyphSize))
                .foregroundStyle(tint)
        }
        .accessibilityHidden(true)
    }
}
#endif
