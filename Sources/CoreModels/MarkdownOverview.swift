import Foundation

/// Media overviews/descriptions (notably AniDB-sourced anime synopses) can arrive
/// with inline markdown links like `[Taiju](http://anidb.net/ch99858)`. Rendered
/// raw they leak brackets + URLs into the UI, so callers convert them: tvOS (no
/// pointer, links aren't tappable) flattens to plain label text; iOS/iPadOS can
/// render tappable links from the parsed attributed form.
public extension String {
    /// Inline-parsed markdown (links + emphasis), whitespace/newlines preserved.
    /// `nil` when parsing fails so callers can fall back to the raw string.
    var overviewMarkdown: AttributedString? {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return try? AttributedString(markdown: self, options: options)
    }

    /// The overview with inline markdown flattened to plain text — a
    /// `[label](url)` link becomes just `label`, no brackets or URL. Used where
    /// links can't be tapped (tvOS) so raw markdown never reaches the screen.
    var overviewPlainText: String {
        guard let attributed = overviewMarkdown else { return self }
        return String(attributed.characters)
    }
}
