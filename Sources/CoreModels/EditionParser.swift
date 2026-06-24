import Foundation

/// Parses a provider's raw media-source *name* into the two human-meaningful
/// facets the version/edition picker needs to make a choice unambiguous:
///
/// - the **edition** — the *cut* of the title (Extended, Theatrical, Director's
///   Cut, Final Cut, Unrated, Remastered, …). This is what most users actually
///   care about when the same film exists twice: a 4K Extended cut is a
///   different thing to watch than a 4K Theatrical cut, even at identical
///   bitrate.
/// - the **source quality** — how the file was produced (Remux, BluRay, WEB-DL,
///   WEBRip, HDTV, DVD, …). A lossless Remux and a re-encoded WEB-DL can both be
///   "4K Direct Play 12 GB" yet be very different in fidelity.
///
/// Today `MediaVersion.displayLabel` collapses everything into "4K · Direct Play
/// · 12 GB" and throws the provider name away, so a user choosing between two
/// 4K files is told nothing that distinguishes them. This pure parser recovers
/// that signal from the (often release-scene-formatted) name, e.g.
/// `"Movie (2009) Extended Bluray-2160p Atmos"` → edition "Extended",
/// source "BluRay".
///
/// It is intentionally dependency-free, allocation-light and case-insensitive,
/// and is exercised by a dedicated test suite. Providers may also supply an
/// edition *explicitly* (Plex's `editionTitle`); that always wins over parsing.
public enum EditionParser {
    /// Known edition phrases, longest/most-specific first so "Extended Director's
    /// Cut" wins over "Extended". **Needles are pre-normalized** (lower-case,
    /// separators → spaces, apostrophes removed) to match ``normalize(_:)``'s
    /// output; each maps to a clean display label.
    private static let editionRules: [(needles: [String], label: String)] = [
        (["ultimate edition", "ultimate cut"], "Ultimate Edition"),
        (["extended directors cut"], "Extended Director's Cut"),
        (["directors cut"], "Director's Cut"),
        (["final cut"], "Final Cut"),
        (["richard donner cut", "donner cut"], "Donner Cut"),
        (["assembly cut"], "Assembly Cut"),
        (["theatrical cut", "theatrical"], "Theatrical"),
        (["extended edition", "extended cut", "extended"], "Extended"),
        (["unrated"], "Unrated"),
        (["uncut"], "Uncut"),
        (["remastered", "remaster"], "Remastered"),
        (["special edition"], "Special Edition"),
        (["collectors edition"], "Collector's Edition"),
        (["anniversary edition", "anniversary"], "Anniversary Edition"),
        (["imax enhanced", "imax"], "IMAX"),
        (["open matte"], "Open Matte"),
        (["redux"], "Redux")
    ]

    /// Known source-quality tokens, longest first. Needles are pre-normalized;
    /// short/ambiguous tokens are space-padded so they only match as whole words.
    private static let sourceRules: [(needles: [String], label: String)] = [
        (["uhd bluray", "uhd blu ray", "uhd bd"], "UHD BluRay"),
        (["bluray remux", "blu ray remux", "bd remux", "remux"], "Remux"),
        (["bluray", "blu ray", "bdrip", "brrip", "bdmv", "bd25", "bd50"], "BluRay"),
        (["web dl", "webdl"], "WEB-DL"),
        (["webrip", "web rip"], "WEBRip"),
        ([" web "], "WEB"),
        (["hdtv"], "HDTV"),
        (["dvdrip", " dvd "], "DVD"),
        (["hdrip"], "HDRip"),
        ([" cam ", "camrip"], "CAM")
    ]

    /// The edition (cut) named by `name`, or `nil` when the name carries no
    /// recognised edition phrase. Matching is case-insensitive and punctuation
    /// tolerant.
    public static func edition(from name: String?) -> String? {
        guard let haystack = normalize(name) else { return nil }
        for rule in editionRules where rule.needles.contains(where: { haystack.contains($0) }) {
            return rule.label
        }
        return nil
    }

    /// The source-quality token named by `name` (Remux, BluRay, WEB-DL, …), or
    /// `nil` when none is recognised.
    public static func sourceQuality(from name: String?) -> String? {
        guard let haystack = normalize(name) else { return nil }
        for rule in sourceRules where rule.needles.contains(where: { haystack.contains($0) }) {
            return rule.label
        }
        return nil
    }

    /// Lower-cases `name` and folds the punctuation release names use as word
    /// separators (`.`, `_`, `-`, brackets) into spaces so token matching is
    /// robust to the many ways `"Director's.Cut"` / `"directors-cut"` are
    /// written. Apostrophes are dropped (not spaced) so `"director's"` becomes
    /// `"directors"`. The result is wrapped in spaces so needles can require
    /// whole-word boundaries.
    private static func normalize(_ name: String?) -> String? {
        guard let name else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var scalars = String.UnicodeScalarView()
        for scalar in trimmed.lowercased().unicodeScalars {
            switch scalar {
            case "'", "\u{2019}":
                continue
            case ".", "_", "-", "/", "(", ")", "[", "]", ":", ",":
                scalars.append(" ")
            default:
                scalars.append(scalar)
            }
        }
        let collapsed = String(scalars)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        return collapsed.isEmpty ? nil : " \(collapsed) "
    }
}
