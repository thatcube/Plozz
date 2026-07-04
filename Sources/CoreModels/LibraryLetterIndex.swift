import Foundation

/// A jump target in an alphabetically-sorted library: a rail letter and the
/// 0-based index of the first item that sorts under it, expressed in the grid's
/// *current* sort direction.
///
/// Powers the trailing "A–Z" fast-scroll rail on the library browse grid: the
/// grid is a sparse, full-size wall sized to the whole library, so jumping to a
/// letter is simply scrolling the grid to that letter's `startIndex` (which then
/// lazily loads the page that owns it).
public struct LibraryLetterIndexEntry: Equatable, Sendable {
    /// The rail bucket this entry represents: `"#"` (digits/symbols that sort
    /// before "A") or a single uppercase Latin letter `"A"`…`"Z"`.
    public let letter: String
    /// 0-based index of the first item under `letter`, in the grid's current
    /// sort order. Feeds `ScrollViewReader.scrollTo(_:)`.
    public let startIndex: Int

    public init(letter: String, startIndex: Int) {
        self.letter = letter
        self.startIndex = startIndex
    }
}

/// Builds a library's alphabet fast-scroll index from per-letter counts. Kept a
/// pure, provider-agnostic value type so both backends (Jellyfin's per-letter
/// `NameLessThan` counts, Plex's `firstCharacter` facet) assemble the same
/// ascending `(letter, count)` buckets and share this offset math — and so the
/// tricky ascending-vs-descending index arithmetic is unit-testable without a
/// network.
public enum LibraryLetterIndex {
    /// The canonical rail buckets, in ascending sort order: the `"#"` catch-all
    /// (digits/symbols) first, then `"A"`…`"Z"`. Providers normalise their raw
    /// first-character data onto these buckets.
    public static let railLetters: [String] = {
        let letters = (UnicodeScalar("A").value...UnicodeScalar("Z").value)
            .compactMap { UnicodeScalar($0).map(String.init) }
        return ["#"] + letters
    }()

    /// Maps a raw first-character/sort-name prefix onto a rail bucket: an
    /// A–Z letter (case-insensitive) maps to its uppercase self; anything else
    /// (digits, symbols, non-Latin) folds into the `"#"` bucket.
    public static func bucket(forPrefix prefix: String) -> String {
        guard let first = prefix.uppercased().first else { return "#" }
        return (first >= "A" && first <= "Z") ? String(first) : "#"
    }

    /// Assembles ordered `LibraryLetterIndexEntry`s from ascending-sorted
    /// `(letter, count)` buckets.
    ///
    /// - Parameters:
    ///   - bucketCountsAscending: each rail bucket paired with how many items
    ///     sort into it, ordered by the *ascending* sort (so `"#"` first, then
    ///     `A`…`Z`). Buckets may be omitted or given `0`; both are treated as
    ///     empty and dropped from the result.
    ///   - direction: the grid's active sort direction. Ascending yields
    ///     `#…Z` with cumulative start offsets; descending yields the mirror
    ///     order (`Z…#`) with the start index of each letter's first item in the
    ///     reversed list.
    /// - Returns: entries ordered by `startIndex` ascending (i.e. top-to-bottom
    ///   as they appear in the grid for `direction`), with empty buckets removed.
    public static func entries(
        bucketCountsAscending: [(letter: String, count: Int)],
        direction: SortDirection
    ) -> [LibraryLetterIndexEntry] {
        let total = bucketCountsAscending.reduce(0) { $0 + max(0, $1.count) }
        guard total > 0 else { return [] }

        var entries: [LibraryLetterIndexEntry] = []
        var cumulativeBefore = 0
        for (letter, rawCount) in bucketCountsAscending {
            let count = max(0, rawCount)
            guard count > 0 else { continue }
            // Ascending: the letter starts right after everything before it.
            // Descending: the whole list is reversed, so this letter's first
            // item is its ascending-last item — total - (items up to & incl it).
            let start = direction == .ascending
                ? cumulativeBefore
                : total - (cumulativeBefore + count)
            entries.append(LibraryLetterIndexEntry(letter: letter, startIndex: start))
            cumulativeBefore += count
        }
        return entries.sorted { $0.startIndex < $1.startIndex }
    }

    /// Assembles the index from *cumulative* "count of items that sort before
    /// this letter" offsets — the shape Jellyfin's `NameLessThan` count queries
    /// naturally produce.
    ///
    /// - Parameters:
    ///   - offsetsByLetter: for each of `A`…`Z`, the number of items whose sort
    ///     name is strictly less than that letter (i.e. `count(SortName < L)`).
    ///     `offsetsByLetter["A"]` therefore equals the size of the `"#"` bucket.
    ///   - totalCount: the library's total item count (the upper bound for the
    ///     final, `Z`-and-beyond bucket).
    ///   - direction: the grid's active sort direction.
    public static func entries(
        lessThanOffsetsByLetter offsetsByLetter: [String: Int],
        totalCount: Int,
        direction: SortDirection
    ) -> [LibraryLetterIndexEntry] {
        guard totalCount > 0 else { return [] }
        let letters = railLetters.filter { $0 != "#" }   // "A"…"Z", ascending.

        // Cumulative offset at the start of each bucket, clamped monotonic and
        // into range so malformed server data can't produce negative counts.
        func offset(before letter: String) -> Int {
            min(max(0, offsetsByLetter[letter] ?? 0), totalCount)
        }

        var buckets: [(letter: String, count: Int)] = []
        // "#" bucket: everything before "A".
        buckets.append((letter: "#", count: offset(before: "A")))
        for (i, letter) in letters.enumerated() {
            let start = offset(before: letter)
            let nextStart: Int = (i + 1 < letters.count)
                ? max(start, offset(before: letters[i + 1]))
                : totalCount
            buckets.append((letter: letter, count: nextStart - start))
        }
        return entries(bucketCountsAscending: buckets, direction: direction)
    }
}
