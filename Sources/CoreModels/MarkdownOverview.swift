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

    /// The overview with link markup flattened to plain text — the label survives,
    /// the URL and brackets don't. Used where links can't be tapped (tvOS) so raw
    /// markup never reaches the screen.
    ///
    /// Covers both forms seen in the wild:
    ///   * markdown — `[label](url)` → `label`
    ///   * AniDB's own syntax — `url [label]` → `label`
    ///
    /// The second arrives through Jellyfin/Plex metadata agents and is common on
    /// anime. It isn't markdown, so the parser leaves it verbatim and a synopsis
    /// opens as a wall of `http://anidb.net/character/…` URLs — unreadable, and on
    /// tvOS not even followable. iOS keeps the raw string and renders real links
    /// (see `overviewMarkdownWithLegibleLinks`); only this flattening path strips
    /// them, so the two platforms stay deliberately different rather than by
    /// accident.
    var overviewPlainText: String {
        let deAniDB = Self.flattenedAniDBLinks(self)
        guard let attributed = deAniDB.overviewMarkdown else { return deAniDB }
        return String(attributed.characters)
    }

    /// `<url> [label]` → `label`.
    ///
    /// Deliberately narrow: only a URL *immediately followed by* a bracketed label
    /// is rewritten. A bare URL is left alone (it may be a genuine "Source:"
    /// credit), and bracketed text with no URL is untouched — including markdown's
    /// `[label](url)`, whose bracket comes first and is handled by the parser.
    ///
    /// Parentheses are excluded from the URL so a *markdown* link can never be
    /// mistaken for this form. Allowing them let the URL run past its own closing
    /// `)` and comma and swallow the following link's label, so a synopsis naming
    /// four characters in a row collapsed into
    /// `[Taichi](Iori(Himeko(Yoshifumi(http://…)` — each link eating the next.
    private static func flattenedAniDBLinks(_ text: String) -> String {
        guard !text.isEmpty, let regex = aniDBLink else { return text }
        let range = NSRange(text.startIndex..., in: text)
        guard regex.firstMatch(in: text, options: [], range: range) != nil else { return text }
        return regex
            .stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "$1")
            // Collapse the doubled space a removal can leave between two words.
            .replacingOccurrences(of: "[ \t]{2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let aniDBLink = try? NSRegularExpression(
        pattern: #"https?://[^\s\[\]()]+[ \t]*\[([^\]]+)\]"#,
        options: []
    )
}
