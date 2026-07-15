#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit
import Observation
import CoreModels

/// The main-actor engine behind the `PLZHERO_RASTER_FOREGROUND` experiment. It
/// prepares the hero's description-column snapshot for a bounded ±2 window of
/// slides **during the auto-advance dwell** (never on a transition frame), keeps
/// the decoded `UIImage`s under a byte budget via ``HeroRasterCacheCore``, and
/// serves an O(1) lookup the view uses to swap a prepared image in on a page.
///
/// ## Where the main-thread work happens
/// `ImageRenderer` renders SwiftUI to a bitmap **on the main actor** — there is no
/// off-main SwiftUI rasterization API — so the render itself is main-thread work.
/// The experiment's whole premise is to move that work *off* the transition frame:
/// ``prepare(items:index:colorScheme:displayScale:makeContent:)`` runs from a
/// dwell `.task`, does the async logo resolve off-main, then renders on the main
/// actor while the slide is sitting idle. `page()` never calls into preparation —
/// it only reads the already-prepared cache. If a render lands on a busy main
/// thread mid-dwell it costs a little there, but never during the wipe.
///
/// ## Correctness guards
/// - **Generation:** every set/settings invalidation bumps the cache generation;
///   a prepare pass captures the generation up front and discards its result if
///   the generation moved while it was rendering (a set swap / theme flip mid-pass
///   can't store a stale snapshot).
/// - **Cancellation:** the dwell `.task` is cancelled on every page/reseat, so a
///   pass for a superseded slide stops before rendering the wrong content.
/// - **Fingerprint:** a lookup only HITs when the stored fingerprint matches the
///   current one, so a snapshot is never shown for changed content.
@MainActor
@Observable
final class HeroForegroundRasterizer {
    /// Soft ceiling on total decoded snapshot bytes (~24 MB ≈ five 900×560@1x
    /// description snapshots with comfortable headroom). Bounds worst-case memory
    /// well under a hero backdrop working set; eviction protects the live window.
    static let defaultByteBudget = 24 * 1024 * 1024

    private var core: HeroRasterCacheCore
    private var images: [String: UIImage] = [:]
    /// Item ids whose stored snapshot was rendered **with** a resolved logo image.
    /// Used to upgrade a text-title snapshot (logo not yet resolved when first
    /// prepared) to a logo snapshot once the logo becomes available, without
    /// putting an async-only "logoReady" bit in the sync-computable fingerprint.
    private var renderedWithLogo: Set<String> = []

    init(byteBudget: Int = defaultByteBudget) {
        core = HeroRasterCacheCore(byteBudget: byteBudget)
    }

    var generation: Int { core.generation }

    // MARK: - Reads (view body)

    /// Side-effect-free read for the view body: the prepared snapshot for
    /// `itemID` iff its fingerprint still matches (else `nil` → live fallback).
    /// Does not record a HIT/MISS — that is done once per transition by
    /// ``recordTransition(itemID:fingerprint:)`` so a re-render can't double-count.
    func image(for itemID: String, fingerprint: HeroForegroundFingerprint) -> UIImage? {
        guard core.contains(itemID: itemID, fingerprint: fingerprint) else { return nil }
        return images[itemID]
    }

    /// Records — once, at the transition frame — whether the fronted slide was
    /// served from a prepared snapshot (HIT) or fell back to the live column
    /// (MISS), and emits the secret-safe marker.
    func recordTransition(itemID: String, fingerprint: HeroForegroundFingerprint) {
        let hit = core.lookup(itemID: itemID, fingerprint: fingerprint)
        if hit {
            HeroRasterExperiment.emitHit(fingerprintHash: fingerprint.loggableHash, generation: core.generation)
        } else {
            HeroRasterExperiment.emitMiss(fingerprintHash: fingerprint.loggableHash, generation: core.generation)
        }
    }

    // MARK: - Invalidation

    /// Drops every prepared snapshot and bumps the generation — call when the
    /// curated slide set changes identity or a snapshot-wide setting (theme,
    /// spoiler policy) flips.
    func invalidateAll(reason: String) {
        let dropped = core.invalidateAll(reason: reason)
        for id in dropped { images.removeValue(forKey: id) }
        renderedWithLogo.removeAll()
        HeroRasterExperiment.emitInvalidated(
            generation: core.generation, dropped: dropped.count, reason: reason
        )
    }

    // MARK: - Preparation (dwell)

    /// Prepares any missing/stale snapshots for the bounded window around `index`,
    /// in paging-priority order. Runs from a dwell `.task`; honours cancellation
    /// between slides and generation changes across the async logo resolve.
    ///
    /// The view supplies two closures that keep the async logo work off the
    /// transition path and the fingerprint synchronously reproducible:
    /// - `fingerprint(item)` — the sync snapshot key the view also computes at the
    ///   transition frame (no logo resolve), so a store here matches a later lookup.
    /// - `makeContent(item)` — the async render inputs, which resolve the logo
    ///   image; only called for a slide that actually needs (re)rendering.
    func prepare(
        items: [MediaItem],
        index: Int,
        colorScheme: ColorScheme,
        displayScale: CGFloat,
        fingerprint: @escaping (MediaItem) -> HeroForegroundFingerprint,
        makeContent: @escaping (MediaItem) async -> HeroForegroundContent?
    ) async {
        guard !items.isEmpty else { return }
        let windowIndices = HeroRasterWindow.indices(count: items.count, centeredAt: index)
        let windowItemIDs = windowIndices.map { items[$0].id }
        let startGeneration = core.generation

        for slideIndex in windowIndices {
            if Task.isCancelled { return }
            let item = items[slideIndex]
            let fp = fingerprint(item)

            // Cheap sync skip: already-fresh AND either it has no logo to upgrade
            // or the stored snapshot already baked the logo.
            let needsFresh = core.needsPreparation(itemID: item.id, fingerprint: fp)
            let wantsLogoUpgrade = !needsFresh
                && fp.logoURLString != nil
                && !renderedWithLogo.contains(item.id)
            guard needsFresh || wantsLogoUpgrade else { continue }

            guard let content = await makeContent(item) else { continue }
            if Task.isCancelled || core.generation != startGeneration { return }

            // A logo-upgrade attempt that still couldn't resolve the logo: leave the
            // text snapshot as-is (retry next dwell) rather than re-rendering identically.
            if !needsFresh && wantsLogoUpgrade && content.logoImage == nil { continue }

            let started = DispatchTime.now().uptimeNanoseconds
            guard let image = render(content: content, colorScheme: colorScheme, displayScale: displayScale) else {
                continue
            }
            if core.generation != startGeneration { return }

            let bytes = byteCost(of: image, scale: displayScale)
            images[item.id] = image
            if content.logoImage != nil { renderedWithLogo.insert(item.id) }
            else { renderedWithLogo.remove(item.id) }
            let evicted = core.store(
                itemID: item.id,
                fingerprint: fp,
                byteCost: bytes,
                windowItemIDs: windowItemIDs
            )
            for id in evicted where id != item.id {
                images.removeValue(forKey: id)
                renderedWithLogo.remove(id)
            }

            let ms = Double(DispatchTime.now().uptimeNanoseconds &- started) / 1_000_000
            HeroRasterExperiment.emitPrepared(
                fingerprintHash: fp.loggableHash,
                generation: core.generation, ms: ms, bytes: bytes
            )
        }

        // Trim any resident snapshots that fell outside the window (e.g. after a
        // long jump) so memory tracks the window even without a store pushing over
        // budget. Never drops an in-window slide.
        let windowSet = Set(windowItemIDs)
        for id in core.storedItemIDs where !windowSet.contains(id) {
            if core.drop(itemID: id) {
                images.removeValue(forKey: id)
                renderedWithLogo.remove(id)
            }
        }

        HeroRasterExperiment.emitCacheState(
            resident: core.count, bytes: core.totalBytes, budget: core.byteBudget
        )
    }

    // MARK: - Rendering

    private func render(
        content: HeroForegroundContent,
        colorScheme: ColorScheme,
        displayScale: CGFloat
    ) -> UIImage? {
        let width = max(320, content.contentWidth > 0 ? content.contentWidth : 960)
        let view = HeroForegroundVisual(content: content, colorScheme: colorScheme)
            .frame(width: width, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        let renderer = ImageRenderer(content: view)
        renderer.scale = displayScale
        renderer.isOpaque = false
        return renderer.uiImage
    }

    private func byteCost(of image: UIImage, scale: CGFloat) -> Int {
        let px = image.size.width * image.scale * image.size.height * image.scale
        return Int(px * 4)
    }

    // MARK: - Introspection (markers / debug)

    var residentCount: Int { core.count }
    var residentBytes: Int { core.totalBytes }
}
#endif
