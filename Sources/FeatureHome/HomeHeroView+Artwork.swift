#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit
import CoreModels
import CoreUI
import MetadataKit

// Artwork resolution / preload for the hero, relocated verbatim from
// HomeHeroView. Same instance methods on the same view (so `index` /
// `resolvedBackdrop` are shared, unchanged) — this file only shrinks the view
// god-object; no behavior change.
extension HomeHeroView {
    // MARK: - Backdrop

    /// The ordered primary backdrop URLs for a slide — mirroring `DetailHeroView`:
    /// the **server's own hero/backdrop art first** (for a Jellyfin episode the
    /// series backdrop rides on `fallbackArtworkURL`; for Plex it's already in
    /// `heroBackdropURL`), then the router-resolved art. The router is only a
    /// *fallback* here (via `backdropFallback`), never the primary — resolving it
    /// first is what made episode slides show a different, low-res image than the
    /// detail page. Any resolved art is prepended (it's the server art for whole
    /// titles, or the router hero only when the server gave none).
    func primaryBackdropURLs(for item: MediaItem) -> [URL] {
        primaryBackdropReferences(for: item).compactMap {
            if case .remote(let url) = $0 { return url }
            return nil
        }
    }

    /// Ordered references preserve direct-share artwork through the same UIKit wipe
    /// as remote artwork. Local references lead; the router keeps its historic
    /// precedence over legacy remote references.
    func primaryBackdropReferences(for item: MediaItem) -> [ArtworkReference] {
        let explicit = item.artworkReferences(for: .homeHero)
        var references = explicit.filter {
            if case .networkFile = $0 { return true }
            return false
        }
        references.append(contentsOf: resolvedBackdrop[item.id].map { [ArtworkReference.remote($0)] } ?? [])
        references.append(contentsOf: explicit.filter {
            if case .remote = $0 { return true }
            return false
        })
        var seen = Set<ArtworkReference>()
        return references.filter { seen.insert($0).inserted }
    }

    // MARK: - Artwork routing / preload

    /// Resolves the fronted slide and warms a bounded two-slide window in each
    /// direction. Five decoded hero images fit comfortably inside the shared cache
    /// while giving sequential remote presses room to stay cache-hot regardless of
    /// whether the carousel contains five slides or twenty.
    func resolveArtwork(around idx: Int) async {
        let targetIndices = HeroArtworkWindow.indices(count: items.count, centeredAt: idx)
        guard !targetIndices.isEmpty else { return }

        // Resolve the visible slide immediately. Full-resolution neighbor warming
        // is speculative and much heavier than the all-slide preview pass, so wait
        // for a real dwell. Rapid presses cancel during this sleep; the small previews
        // get the background lanes first instead of waiting behind four 2000px decodes.
        _ = await HomePerfDiagnostics.measureArtwork {
            await resolveArtworkURL(for: items[targetIndices[0]])
        }
        try? await Task.sleep(nanoseconds: 600_000_000)
        guard !Task.isCancelled else { return }

        var warmURLs: [URL] = []
        for itemIndex in targetIndices.dropFirst() {
            guard !Task.isCancelled else { return }
            if let url = await resolveArtworkURL(for: items[itemIndex]) {
                warmURLs.append(url)
            }
        }

        var seen = Set<URL>()
        let uniqueWarmURLs = warmURLs.filter { seen.insert($0).inserted }
        await withTaskGroup(of: Void.self) { group in
            for url in uniqueWarmURLs {
                group.addTask(priority: .utility) {
                    guard !Task.isCancelled else { return }
                    await ArtworkSession.warmLimiter.run {
                        guard !Task.isCancelled else { return }
                        _ = await ArtworkImageCache.shared.image(
                            for: url,
                            variant: .heroBackdrop,
                            background: true
                        )
                    }
                }
            }
        }
    }

    /// Warms one lightweight progressive frame for the full curated hero set.
    /// Existing full-resolution or landscape-card decodes already satisfy the
    /// instant path and are not duplicated. Work starts immediately and proceeds
    /// in likely paging order (current, next, previous, then expanding outward), so
    /// the first remote presses become cache-hot before distant slides. Small
    /// bounded batches avoid creating a long, cancellation-insensitive limiter
    /// queue when a curated set is replaced.
    func warmHeroPreviews() async {
        var targets: [HeroPreviewWarmTarget] = []
        let orderedIndices = HeroPreviewWarmOrder.indices(count: items.count, centeredAt: index)
        for itemIndex in orderedIndices {
            guard !Task.isCancelled else { return }
            let item = items[itemIndex]
            let candidates = primaryBackdropReferences(for: item)
            guard !candidates.isEmpty else { continue }
            targets.append(
                HeroPreviewWarmTarget(
                    itemID: item.id,
                    candidates: candidates,
                    asyncFallbackURL: backdropFallback(for: item)
                )
            )
        }

        #if canImport(UIKit)
        let uncached = targets.filter { target in
            !HeroBackdropArtworkPolicy.hasUsableCachedArtwork(for: target.candidates)
        }
        let batchSize = 4
        var fallbackTargets: [HeroPreviewWarmTarget] = []
        var batchStart = 0
        while batchStart < uncached.count {
            guard !Task.isCancelled else { return }
            let batchEnd = min(batchStart + batchSize, uncached.count)
            let failures = await withTaskGroup(
                of: HeroPreviewWarmTarget?.self,
                returning: [HeroPreviewWarmTarget].self
            ) { group in
                for target in uncached[batchStart..<batchEnd] {
                    group.addTask(priority: .utility) {
                        guard !Task.isCancelled else { return nil }
                        let usable = await ArtworkSession.warmLimiter.run {
                            guard !Task.isCancelled else { return false }
                            return await HeroBackdropArtworkPolicy.warmFirstUsablePreview(
                                for: target.candidates
                            )
                        }
                        return usable ? nil : target
                    }
                }
                var failures: [HeroPreviewWarmTarget] = []
                for await failure in group {
                    if let failure { failures.append(failure) }
                }
                return failures
            }
            fallbackTargets.append(contentsOf: failures)
            batchStart = batchEnd
        }

        // Only malformed/failed provider candidates reach this phase. Resolve their
        // router fallbacks after every ordinary slide has had its preview chance,
        // and never hold an artwork-network permit while metadata resolution runs.
        batchStart = 0
        while batchStart < fallbackTargets.count {
            guard !Task.isCancelled else { return }
            let batchEnd = min(batchStart + batchSize, fallbackTargets.count)
            let resolvedFallbacks = await withTaskGroup(
                of: ResolvedHeroPreviewFallback?.self,
                returning: [ResolvedHeroPreviewFallback].self
            ) { group in
                for target in fallbackTargets[batchStart..<batchEnd] {
                    group.addTask(priority: .utility) {
                        guard !Task.isCancelled,
                              let resolver = target.asyncFallbackURL,
                              let url = await resolver(),
                              !Task.isCancelled,
                              !target.candidates.contains(.remote(url))
                        else {
                            return nil
                        }
                        return ResolvedHeroPreviewFallback(itemID: target.itemID, url: url)
                    }
                }
                var resolved: [ResolvedHeroPreviewFallback] = []
                for await fallback in group {
                    if let fallback { resolved.append(fallback) }
                }
                return resolved
            }

            for fallback in resolvedFallbacks {
                guard !Task.isCancelled else { return }
                resolvedBackdrop[fallback.itemID] = fallback.url
            }
            await withTaskGroup(of: Void.self) { group in
                for fallback in resolvedFallbacks {
                    group.addTask(priority: .utility) {
                        guard !Task.isCancelled else { return }
                        await ArtworkSession.warmLimiter.run {
                            guard !Task.isCancelled else { return }
                            _ = await HeroBackdropArtworkPolicy.warmFirstUsablePreview(
                                for: [.remote(fallback.url)]
                            )
                        }
                    }
                }
            }
            batchStart = batchEnd
        }
        #endif
    }

    /// Prepares provider-supplied logos in the same current/next/previous order as
    /// backdrop previews. Two-at-a-time warming stays lightweight and avoids
    /// launching external metadata searches for slides that have no provider logo;
    /// those retain the immediate text title and resolve their optional fallback on
    /// demand without ever becoming visually blank.
    func warmHeroLogos() async {
        try? await Task.sleep(nanoseconds: 350_000_000)
        guard !Task.isCancelled else { return }

        var seen = Set<String>()
        let orderedReferences = HeroPreviewWarmOrder.indices(count: items.count, centeredAt: index)
            .flatMap { items[$0].artworkReferences(for: .logo) }
            .filter { seen.insert($0.privacySafeIdentity).inserted }
        let batchSize = 2
        var batchStart = 0
        while batchStart < orderedReferences.count {
            guard !Task.isCancelled else { return }
            let batchEnd = min(batchStart + batchSize, orderedReferences.count)
            await withTaskGroup(of: Void.self) { group in
                for reference in orderedReferences[batchStart..<batchEnd] {
                    group.addTask(priority: .utility) {
                        guard !Task.isCancelled else { return }
                        await ArtworkSession.warmLimiter.run {
                            guard !Task.isCancelled else { return }
                            await HeroLogoPreloader.warm(references: [reference])
                        }
                    }
                }
            }
            batchStart = batchEnd
        }
    }

    /// Resolves the best hero backdrop URL for one item. Mirrors
    /// `DetailHeroView`: prefer the **server's** hero art
    /// (for an episode/season, the series backdrop carried on `fallbackArtworkURL`
    /// — the same art the detail page shows), and only reach for the router when
    /// the server provided none. Resolving the router *first* for episodes was the
    /// "wrong / low-res image" bug.
    @MainActor
    func resolveArtworkURL(for item: MediaItem) async -> URL? {
        guard !Task.isCancelled else { return nil }
        if let resolved = resolvedBackdrop[item.id] { return resolved }
        // Direct-share candidates already flow through HomeHeroBackdrop's ordered
        // reference pipeline. Do not prepend a router URL over those explicit local
        // selections; its async fallback is invoked only after they fail.
        if item.artworkReferences(for: .homeHero).contains(where: {
            if case .networkFile = $0 { return true }
            return false
        }) {
            return nil
        }
        var best: URL? = item.heroBackdropURL ?? item.backdropURL ?? item.fallbackArtworkURL
        switch item.kind {
        case .folder, .collection, .unknown:
            break // server art only; no external router for containers
        default:
            if best == nil {
                best = await ArtworkRouter.shared.artworkURL(.hero, for: item)
            }
        }
        guard !Task.isCancelled, let url = best else { return nil }
        resolvedBackdrop[item.id] = url
        return url
    }

    // MARK: - External-art fallbacks (mirror DetailHeroView)

    func backdropFallback(for item: MediaItem) -> (@Sendable () async -> URL?)? {
        switch item.kind {
        case .folder, .collection, .unknown: return nil
        default: break
        }
        // art → TMDb hero → the item's own poster. Some titles (e.g. a Plex movie
        // with a poster but no fanart/`art`) have no landscape backdrop anywhere;
        // rather than leave the hero blank, fall back to the poster so the user
        // still sees the artwork the server does have. Only reached when the
        // primary backdrop URLs fail, so a title with real backdrop art is
        // unaffected.
        return {
            if let hero = await ArtworkRouter.shared.artworkURL(.hero, for: item) { return hero }
            return item.posterURL
        }
    }

    func logoFallback(for item: MediaItem) -> (@Sendable () async -> URL?)? {
        switch item.kind {
        case .folder, .collection, .unknown: return nil
        default: break
        }
        return { await ArtworkRouter.shared.artworkURL(.logo, for: item) }
    }

    func backgroundSample(for item: MediaItem) -> (@Sendable () async -> HeroBackgroundSample?)? {
        #if canImport(UIKit)
        let references = primaryBackdropReferences(for: item)
        return {
            if let sample = await HeroBackgroundSampler.sample(references: references) { return sample }
            if let tmdb = await ArtworkRouter.shared.artworkURL(.hero, for: item),
               let sample = await HeroBackgroundSampler.sample(urls: [tmdb]) { return sample }
            if let poster = item.posterURL,
               let sample = await HeroBackgroundSampler.sample(urls: [poster]) { return sample }
            return nil
        }
        #else
        return nil
        #endif
    }

    struct HeroPreviewWarmTarget: Sendable {
        let itemID: String
        let candidates: [ArtworkReference]
        let asyncFallbackURL: (@Sendable () async -> URL?)?
    }

    struct ResolvedHeroPreviewFallback: Sendable {
        let itemID: String
        let url: URL
    }
}
#endif
