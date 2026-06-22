import Foundation
import CoreModels

/// A stable, provider-agnostic identity for a search result, used to recognise
/// when the *same* title shows up on more than one server (e.g. a movie that
/// lives on both a Jellyfin and a Plex account).
///
/// Two flavours, in priority order:
/// - `.external` — a shared strong external id (IMDb, TMDb, …). The most
///   reliable signal because both servers reference the same catalogue entry.
/// - `.title` — the normalized title + release year + media kind, the fallback
///   when no external id is present.
public enum SearchIdentity: Hashable, Sendable {
    case external(source: String, value: String)
    case title(normalizedTitle: String, year: Int?, kind: MediaItemKind)
}

/// Pure, UI-free de-duplication for aggregated search results.
///
/// When several accounts are searched at once the same title can come back more
/// than once. `deduplicate` collapses those into a single card while keeping
/// references to *every* source account so playback still resolves regardless of
/// which server the user lands on.
public enum SearchDeduplicator {
    /// External id namespaces that uniquely identify a catalogue entry across
    /// providers, in match-priority order. Lower-cased for case-insensitive
    /// comparison against `MediaItem.providerIDs` keys.
    private static let strongExternalSources = ["imdb", "tmdb", "tvdb"]

    /// The candidate identities for an item, strongest first. Two items are the
    /// same result when *any* of their identities match.
    static func identities(for item: MediaItem) -> [SearchIdentity] {
        var result: [SearchIdentity] = []

        // Strong external ids first, in a deterministic priority order.
        let normalizedIDs = Dictionary(
            item.providerIDs.compactMap { key, value -> (String, String)? in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : (key.lowercased(), trimmed.lowercased())
            },
            uniquingKeysWith: { first, _ in first }
        )
        for source in strongExternalSources {
            if let value = normalizedIDs[source] {
                result.append(.external(source: source, value: value))
            }
        }

        // Title fallback — ONLY when no strong external IDs are present.
        // An item with a TMDb/IMDb/TVDb ID has a well-defined catalogue identity;
        // adding a title key on top risks bridging two completely different shows
        // that happen to share a name (and year) via false transitive merges.
        // E.g. an anime (tvdb=A, year=1999) and its live-action remake
        // (tvdb=B, year=1999-in-bad-metadata) would otherwise collapse because
        // they share .title("one piece", 1999, .series).
        if result.isEmpty, let titleIdentity = titleIdentity(for: item) {
            result.append(titleIdentity)
        }
        return result
    }

    private static func titleIdentity(for item: MediaItem) -> SearchIdentity? {
        guard let year = item.productionYear else { return nil }
        let normalized = normalizedTitle(item.title)
        guard !normalized.isEmpty else { return nil }
        return .title(normalizedTitle: normalized, year: year, kind: item.kind)
    }

    /// Canonical title form: lower-cased, accent-folded, punctuation removed and
    /// internal whitespace collapsed so "Spider-Man" and "spider man" match.
    static func normalizedTitle(_ raw: String) -> String {
        let folded = raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let stripped = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(stripped)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    /// Collapses duplicate items that refer to the same title across providers
    /// into a single merged item, preserving the input's relevance order.
    ///
    /// Determinism: the **first** occurrence of a duplicate set wins as the
    /// primary (so the round-robin interleave order is respected), the merged
    /// item unions every source's `providerIDs`, and `additionalSourceAccountIDs`
    /// lists the other accounts (de-duplicated, first-seen order) so playback can
    /// fall back to any server that has the title.
    public static func deduplicate(_ items: [MediaItem]) -> [MediaItem] {
        guard items.count > 1 else { return items }

        // Union-find over item indices, joined whenever two items share any
        // identity. Handles transitive matches (A↔B by IMDb, B↔C by title ⇒ all
        // one group) deterministically.
        var parent = Array(items.indices)

        func find(_ index: Int) -> Int {
            var root = index
            while parent[root] != root { root = parent[root] }
            var node = index
            while parent[node] != node {
                let next = parent[node]
                parent[node] = root
                node = next
            }
            return root
        }

        func union(_ a: Int, _ b: Int) {
            let rootA = find(a)
            let rootB = find(b)
            guard rootA != rootB else { return }
            // Keep the lower index as the root so the first occurrence stays primary.
            if rootA < rootB { parent[rootB] = rootA } else { parent[rootA] = rootB }
        }

        var seen: [SearchIdentity: Int] = [:]
        for index in items.indices {
            for identity in identities(for: items[index]) {
                if let existing = seen[identity] {
                    union(existing, index)
                } else {
                    seen[identity] = index
                }
            }
        }

        // Gather members per group, preserving order.
        var membersByRoot: [Int: [Int]] = [:]
        for index in items.indices {
            membersByRoot[find(index), default: []].append(index)
        }

        var output: [MediaItem] = []
        var emitted = Set<Int>()
        for index in items.indices {
            let root = find(index)
            guard !emitted.contains(root) else { continue }
            emitted.insert(root)
            let members = membersByRoot[root] ?? [index]
            output.append(merge(members.map { items[$0] }))
        }
        return output
    }

    /// Merges a duplicate set (already in relevance order) into one item: the
    /// first is primary, external ids are unioned, and the remaining distinct
    /// source accounts become `additionalSourceAccountIDs`.
    private static func merge(_ duplicates: [MediaItem]) -> MediaItem {
        guard var primary = duplicates.first else {
            preconditionFailure("merge requires at least one item")
        }
        guard duplicates.count > 1 else { return primary }

        var providerIDs = primary.providerIDs
        for duplicate in duplicates.dropFirst() {
            for (key, value) in duplicate.providerIDs where providerIDs[key] == nil {
                providerIDs[key] = value
            }
        }
        primary.providerIDs = providerIDs

        var alternates: [String] = []
        var seenAccounts = Set(primary.sourceAccountID.map { [$0] } ?? [])
        for duplicate in duplicates.dropFirst() {
            guard let account = duplicate.sourceAccountID, !seenAccounts.contains(account) else { continue }
            seenAccounts.insert(account)
            alternates.append(account)
        }
        primary.additionalSourceAccountIDs = alternates
        return primary
    }
}
