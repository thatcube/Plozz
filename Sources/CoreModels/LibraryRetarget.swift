import Foundation

public extension MediaItem {
    /// Rewrites an external/discovery row the viewer turns out to own, using the
    /// identity index's evidence.
    ///
    /// This existed twice — once for a person's credits, once for the Related row —
    /// with **different rules**, which is the shape of bug this whole layer exists to
    /// end. The credits version required no strong id and did not scope by kind, so a
    /// TMDb integer shared between a movie and a series (the id spaces are separate:
    /// movie 550 ≠ tv 550) could hand a credit the wrong work's servers. The Related
    /// version had both guards. This is the union of the two, taking the conservative
    /// rule from each.
    ///
    /// Returns `nil` when the item must be left exactly as it is — which is most of
    /// the time, and deliberately: never becoming a metadata authority means
    /// declining to claim ownership on weak evidence.
    ///
    /// - Parameters:
    ///   - indexedSources: the live identity-index lookup. In-memory and snapshot
    ///     backed; safe on a publish path, never on a card path.
    ///   - capabilities: when supplied, a concrete source is also selected and the
    ///     item retargeted onto it, because the caller needs an id a server can
    ///     actually load (a credit's own id is a provider id like `tmdb:tv:456`).
    ///     Pass `nil` to attach the evidence and let the detail page select.
    func retargetedToOwnedLibraryCopy(
        indexedSources: (MediaItem) -> [MediaSourceRef],
        capabilities: MediaCapabilities? = nil
    ) -> MediaItem? {
        // Only a discovery row is a candidate: an ordinary library item is already
        // pointed at its own server, and `availability` is what marks the difference.
        guard isNotInLibraryDiscovery else { return nil }

        // A strong external id is required. A title/year-only match is not enough to
        // retarget on, because being wrong here doesn't just mislabel a card — it
        // routes playback to a different work.
        //
        // "Strong" means *an id the identity index actually keys by* — which
        // includes a bare `PlexGuid`. It did not, once, and the mismatch was the
        // whole of issue #33: a Plex Watchlist row carries only `plex://<type>/<id>`
        // for any title Discover couldn't match to IMDb/TMDb/TVDb (anime, foreign,
        // locally-matched), so this gate rejected it before `indexedSources` was
        // ever consulted — and a film the viewer owns opened as a request page.
        guard MediaItemIdentity.hasStrongRetargetIdentity(self) else { return nil }

        // Kind-scoped: TMDb/TVDb reuse one integer id space across movies and series.
        let owned = indexedSources(self).filter { $0.kind == nil || $0.kind == kind }
        guard !owned.isEmpty else { return nil }

        var resolved = self
        if let capabilities {
            guard let selected = CrossSourceSelector.bestSelection(
                from: owned,
                capabilities: capabilities
            ) else { return nil }
            resolved = resolved.selectingSource(selected.source)
        }
        // `.unknown`/`.pending` describes the metadata provider's view, not the copy
        // the index just vouched for. Keeping it would leave the item claiming both,
        // and the card badge is deliberately fail-closed on that field.
        resolved.availability = nil
        resolved.locallyValidatedPlayableSource = true
        var seen = Set<String>()
        resolved.sources = (sources + owned).filter { seen.insert($0.id).inserted }
        return resolved
    }
}
