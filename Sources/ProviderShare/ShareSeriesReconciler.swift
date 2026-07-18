import Foundation
import SQLite3
import CoreModels

/// Transaction-bound series equivalence/merge policy for the share catalog. It runs
/// through the store-owned, actor-confined `CatalogConnection` inside the store's
/// current `saveEnrichment` transaction and never owns a second connection, actor,
/// or long-lived state. It reports the canonical ids it merged into back to the
/// store (which schedules the local-projection repairs) rather than reaching into
/// store state, so the reconciliation mechanics live here while orchestration stays
/// in `ShareCatalogStore`.
struct ShareSeriesReconciler {
    let connection: CatalogConnection

    /// Outcome of a strong-id reconciliation pass: whether the derived catalog
    /// mutations succeeded, plus the canonical series ids that absorbed a loser (so
    /// the store can materialize their cached local metadata after commit).
    struct Outcome {
        var ok: Bool
        var mergedCanonicalIDs: [String]
    }

    private enum MergeResult {
        case noop
        case merged
        case failed
    }

    /// The strong (authoritative) external-id namespaces, in preference order, that
    /// are trustworthy enough to prove two series are the SAME show.
    private static let strongIDNamespaces = ["Tvdb", "Imdb", "Tmdb"]

    /// Fold `key` together with any OTHER already-enriched series that shares one of
    /// its strong external ids AND is near-identically titled (a typo/plural folder
    /// like "Peaky Blinder" vs "Peaky Blinders"). The shared id is the authoritative
    /// signal; the title check is a conservative guard so a provider mis-id can never
    /// collapse two genuinely different shows.
    func reconcileSeriesByStrongID(
        key: String,
        ids: [String: String],
        resolvedTitle: String?
    ) -> Outcome {
        var mergedCanonicalIDs: [String] = []
        guard connection.db != nil else { return Outcome(ok: false, mergedCanonicalIDs: mergedCanonicalIDs) }
        let myStrong = Self.strongIDNamespaces.compactMap { ns -> (String, String)? in
            guard let v = ids[ns], !v.isEmpty else { return nil }
            return (ns.lowercased(), v.lowercased())
        }
        guard !myStrong.isEmpty else { return Outcome(ok: true, mergedCanonicalIDs: mergedCanonicalIDs) }
        let mySet = Set(myStrong.map { "\($0.0):\($0.1)" })

        // Candidate other series carrying at least one of the same strong ids.
        var candidates: [String] = []
        connection.query("SELECT item_id, provider_ids_json FROM enrichment WHERE item_id LIKE 'series:%';") { stmt in
            guard let itemID = CatalogConnection.columnText(stmt, 0),
                  let k = ShareCatalogID.seriesKey(forSeriesID: itemID), k != key,
                  let json = CatalogConnection.columnText(stmt, 1),
                  let other = CatalogJSON.decode([String: String].self, json) else { return }
            let otherSet = Set(Self.strongIDNamespaces.compactMap { ns -> String? in
                guard let v = other[ns], !v.isEmpty else { return nil }
                return "\(ns.lowercased()):\(v.lowercased())"
            })
            if !mySet.isDisjoint(with: otherSet) { candidates.append(k) }
        }
        guard !candidates.isEmpty else { return Outcome(ok: true, mergedCanonicalIDs: mergedCanonicalIDs) }

        let myTitle = seriesDisplayTitle(forKey: key)
        for other in candidates {
            let otherTitle = seriesDisplayTitle(forKey: other)
            guard ShareTitleSimilarity.titlesNearlyIdentical(myTitle, otherTitle) else { continue }
            let (canonical, loser) = chooseCanonicalSeries(key, other, resolvedTitle: resolvedTitle)
            switch mergeSeries(loser: loser, into: canonical) {
            case .noop:
                continue
            case .merged:
                mergedCanonicalIDs.append(ShareCatalogID.series(canonical))
            case .failed:
                return Outcome(ok: false, mergedCanonicalIDs: mergedCanonicalIDs)
            }
        }
        return Outcome(ok: true, mergedCanonicalIDs: mergedCanonicalIDs)
    }

    /// All alias→canonical series-merge rows as a map, for in-memory resolution.
    func seriesMergeMap() -> [String: String] {
        var map: [String: String] = [:]
        connection.query("SELECT alias_key, canonical_key FROM series_merge;") { stmt in
            guard let a = CatalogConnection.columnText(stmt, 0), let c = CatalogConnection.columnText(stmt, 1) else { return }
            map[a] = c
        }
        return map
    }

    /// Resolve a series key through the alias map, following chains (bounded) so a
    /// transitively-merged key still lands on the final canonical.
    static func resolveAlias(_ key: String, in map: [String: String]) -> String {
        var current = key
        var seen = Set<String>()
        while let next = map[current], next != current, seen.insert(current).inserted {
            current = next
        }
        return current
    }

    // MARK: - Canonical selection

    /// A representative display title for a series key (any episode's `series_title`).
    private func seriesDisplayTitle(forKey key: String) -> String {
        var title = key
        connection.query("""
        SELECT series_title FROM assets
        WHERE series_key=? AND kind='episode' AND series_title IS NOT NULL AND series_title <> ''
        LIMIT 1;
        """, bind: { CatalogConnection.bindText($0, 1, key) }) { stmt in title = CatalogConnection.columnText(stmt, 0) ?? key }
        return title
    }

    /// Which of two same-id series is canonical: prefer the one whose title matches
    /// the resolved canonical name; else more episodes; else the lexicographically
    /// smaller key (stable). Returns `(canonical, loser)`.
    private func chooseCanonicalSeries(_ a: String, _ b: String, resolvedTitle: String?) -> (String, String) {
        if let resolved = resolvedTitle.map({ MediaItemIdentity.normalizedTitle($0) }), !resolved.isEmpty {
            let na = MediaItemIdentity.normalizedTitle(seriesDisplayTitle(forKey: a))
            let nb = MediaItemIdentity.normalizedTitle(seriesDisplayTitle(forKey: b))
            if na == resolved, nb != resolved { return (a, b) }
            if nb == resolved, na != resolved { return (b, a) }
        }
        let ea = seriesEpisodeCount(a), eb = seriesEpisodeCount(b)
        if ea != eb { return ea > eb ? (a, b) : (b, a) }
        return a <= b ? (a, b) : (b, a)
    }

    private func seriesEpisodeCount(_ key: String) -> Int {
        var n = 0
        connection.query("SELECT COUNT(*) FROM assets WHERE series_key=? AND kind='episode';",
              bind: { CatalogConnection.bindText($0, 1, key) }) { stmt in n = Int(sqlite3_column_int64(stmt, 0)) }
        return n
    }

    /// Physically fold `loser` into `canonical`: re-key its assets, record the alias
    /// (so a re-scan re-applies it), retarget any aliases that pointed at `loser`,
    /// and drop the loser's now-redundant enrichment row.
    private func mergeSeries(loser: String, into canonical: String) -> MergeResult {
        guard loser != canonical else { return .noop }
        let loserID = ShareCatalogID.series(loser)
        let merged = connection.runUpdate("UPDATE assets SET series_key=? WHERE series_key=?;") {
            CatalogConnection.bindText($0, 1, canonical)
            CatalogConnection.bindText($0, 2, loser)
        } && connection.runUpdate("INSERT OR REPLACE INTO series_merge(alias_key, canonical_key) VALUES (?,?);") {
            CatalogConnection.bindText($0, 1, loser)
            CatalogConnection.bindText($0, 2, canonical)
        } && connection.runUpdate("UPDATE series_merge SET canonical_key=? WHERE canonical_key=?;") {
            CatalogConnection.bindText($0, 1, canonical)
            CatalogConnection.bindText($0, 2, loser)
        } && connection.runUpdate("""
            INSERT OR IGNORE INTO metadata_values(
              item_id, field, source, value_json, source_url,
              source_revision, refreshed_at, expires_at
            )
            SELECT ?, field, source, value_json, source_url,
                   source_revision, refreshed_at, expires_at
            FROM metadata_values
            WHERE item_id=? AND source IN ('localNFO','filename');
            """) {
            CatalogConnection.bindText($0, 1, ShareCatalogID.series(canonical))
            CatalogConnection.bindText($0, 2, loserID)
        } && connection.runUpdate("""
            UPDATE local_metadata_files SET associated_item_id=?
            WHERE associated_item_id=?;
            """) {
            CatalogConnection.bindText($0, 1, ShareCatalogID.series(canonical))
            CatalogConnection.bindText($0, 2, loserID)
        } && connection.runUpdate("DELETE FROM enrichment WHERE item_id=?;") {
            CatalogConnection.bindText($0, 1, loserID)
        } && connection.runUpdate("DELETE FROM metadata_values WHERE item_id=?;") {
            CatalogConnection.bindText($0, 1, loserID)
        } && connection.runUpdate("DELETE FROM metadata_enrichment_state WHERE item_id=?;") {
            CatalogConnection.bindText($0, 1, loserID)
        }
        return merged ? .merged : .failed
    }
}
