#if canImport(SwiftUI)
import SwiftUI
import CoreModels

public extension AttributedString {
    /// Restyle inline-markdown link runs so they stay legible on media surfaces.
    ///
    /// SwiftUI renders markdown links (e.g. AniDB `[Sei](…)` synopsis links) in the
    /// app accent — a mid blue — which drops well below the contrast of the white
    /// body text on a dark hero scrim. Rather than trade the "this is a link" signal
    /// for legibility (or vice-versa), this recolors link runs to a caller-supplied
    /// high-contrast color (normally the theme's primary text color, so it matches
    /// the surrounding copy) and underlines them, keeping links clearly distinct
    /// *and* readable. Pass the palette color for the current surface so it stays
    /// theme-aware in both light and dark.
    func legibleLinks(color: Color, underline: Bool = true) -> AttributedString {
        var copy = self
        let linkRanges = copy.runs.filter { $0.link != nil }.map(\.range)
        for range in linkRanges {
            copy[range].foregroundColor = color
            if underline {
                copy[range].underlineStyle = .single
            }
        }
        return copy
    }
}

public extension String {
    /// The overview parsed as inline markdown with links restyled for legibility,
    /// falling back to the plain string when parsing fails. Links are blended a
    /// little toward `accent` (so they read as tinted, not just underlined body
    /// text) and softened slightly below full contrast — distinct without dropping
    /// to the hard-to-read pure-accent blue. The single entry point iOS/iPadOS
    /// overview render sites use so links read the same everywhere.
    func overviewMarkdownWithLegibleLinks(
        textColor: Color,
        accent: Color
    ) -> AttributedString {
        let linkColor = textColor
            .mix(with: accent, by: 0.38)
            .opacity(0.9)
        return (overviewMarkdown ?? AttributedString(self)).legibleLinks(color: linkColor)
    }
}
#endif
