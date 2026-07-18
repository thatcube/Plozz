import Foundation
import CoreModels

/// Pure title-similarity policy used to decide whether two series titles are a
/// typo/plural of the same show, and whether a display-title upgrade would smuggle
/// in a non-canonical variant word. No SQLite/transport/state — extracted from
/// `ShareCatalogStore` so both the read projection and the series reconciler share
/// one conservative merge/upgrade gate.
enum ShareTitleSimilarity {
    /// Non-canonical "variant" words that must never be introduced by a display-title
    /// upgrade: a base show ("Sword Art Online") must not become a parody/recap
    /// ("Sword Art Online: Abridged") even if a bad match slips through.
    private static let variantWords: Set<String> = [
        "abridged", "recap", "parody", "condensed", "compilation", "fandub", "gagdub", "reaction",
    ]

    /// Whether `extended` (a normalized word-prefix-extension of `base`) adds a
    /// variant word not present in `base`.
    static func addsVariantWord(base: String, extended: String) -> Bool {
        let baseTokens = Set(base.split(separator: " ").map(String.init))
        let addedTokens = Set(extended.split(separator: " ").map(String.init)).subtracting(baseTokens)
        return !addedTokens.isDisjoint(with: variantWords)
    }

    /// Whether two series titles are near-identical enough to be a typo/plural of
    /// one show (Levenshtein ≤ 2 on the normalized forms, no DIGIT difference, and
    /// long enough that a couple of edits isn't most of the title). Combined with a
    /// shared strong id this is a very tight merge gate.
    static func titlesNearlyIdentical(_ a: String, _ b: String) -> Bool {
        let na = MediaItemIdentity.normalizedTitle(a)
        let nb = MediaItemIdentity.normalizedTitle(b)
        guard !na.isEmpty, !nb.isEmpty, na != nb else { return na == nb && !na.isEmpty }
        // A digit difference marks a deliberate distinction (1883 vs 1923, sequels).
        let digitsA = na.filter { $0.isNumber }, digitsB = nb.filter { $0.isNumber }
        guard digitsA == digitsB else { return false }
        let dist = levenshtein(na, nb)
        let shorter = min(na.count, nb.count)
        // Long enough that a couple of edits isn't a big fraction of the title — a
        // 5-letter word like "Fargo"/"Cargo" is one edit apart yet distinct.
        return dist <= 2 && shorter >= 8 && dist * 6 <= shorter
    }

    /// Classic Levenshtein edit distance (two-row DP).
    static func levenshtein(_ a: String, _ b: String) -> Int {
        let s = Array(a), t = Array(b)
        if s.isEmpty { return t.count }
        if t.isEmpty { return s.count }
        var prev = Array(0...t.count)
        var curr = [Int](repeating: 0, count: t.count + 1)
        for i in 1...s.count {
            curr[0] = i
            for j in 1...t.count {
                let cost = s[i - 1] == t[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[t.count]
    }
}
