#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit
import CoreModels
import CoreUI

/// SwiftUI bridge for the **imperative UIKit hero foreground** (POC, gated by
/// ``HeroForegroundConfig``). It hosts a single persistent ``HeroForegroundUIView``
/// and, on every SwiftUI update, hands the coordinator the current slide's
/// ``HeroForegroundModel`` plus a bounded set of neighbour models to pre-prepare.
///
/// The persistent view is never rebuilt across a page: the coordinator only
/// *applies* the new model's values in place (labels/images/frames), which is the
/// whole point — no SwiftUI view-tree diff/relayout of the foreground per
/// transition (the measured source of the hero page hitch).
struct HeroForegroundRepresentable: UIViewRepresentable {
    /// The fronted slide's visuals.
    let model: HeroForegroundModel
    /// Neighbour slides (previous / next) to prepare off-transition so a page finds
    /// the model + logo already warm (a bounded window — see the coordinator).
    let neighbours: [HeroForegroundModel]
    /// Async `.logo` URL resolvers by itemID, mirroring the SwiftUI hero's
    /// `asyncFallbackURL`. Most items carry no baked `logoURL`, so the real logo (the
    /// series logo for an episode) is resolved on demand via `ArtworkRouter`. Keyed to
    /// the current slide + its prepared neighbours so it stays bounded.
    let logoFallbacks: [String: @Sendable () async -> URL?]
    /// Whether the show description (logo/metadata/overview/pills) is currently
    /// shown; the SwiftUI hero snaps this to `false` on a page and back to `true`
    /// ~280ms later. The renderer mirrors it as an imperative alpha animation.
    let metadataVisible: Bool
    let width: CGFloat
    let height: CGFloat

    func makeCoordinator() -> HeroForegroundCoordinator { HeroForegroundCoordinator() }

    func makeUIView(context: Context) -> HeroForegroundUIView {
        let view = HeroForegroundUIView()
        context.coordinator.view = view
        context.coordinator.logoFallbacks = logoFallbacks
        context.coordinator.configure(width: width, height: height)
        context.coordinator.prepare(neighbours)
        context.coordinator.apply(model, metadataVisible: metadataVisible)
        return view
    }

    func updateUIView(_ uiView: HeroForegroundUIView, context: Context) {
        context.coordinator.view = uiView
        context.coordinator.logoFallbacks = logoFallbacks
        context.coordinator.configure(width: width, height: height)
        context.coordinator.prepare(neighbours)
        context.coordinator.apply(model, metadataVisible: metadataVisible)
    }

    static func dismantleUIView(_ uiView: HeroForegroundUIView, coordinator: HeroForegroundCoordinator) {
        uiView.stopContinuousUpdates()
        coordinator.cancelLoads()
    }
}

/// Owns the persistent view, generation-safe async logo loading, and the bounded
/// prepared-model window. Keeps the current applied model so a redundant SwiftUI
/// update (same values) is a cheap no-op and a genuine change is a single in-place
/// apply.
@MainActor
final class HeroForegroundCoordinator {
    weak var view: HeroForegroundUIView?

    /// The model currently rendered on screen. A same-value re-apply is skipped.
    private var appliedModel: HeroForegroundModel?
    /// Whether the description block is currently shown (mirrors `metadataVisible`).
    private var appliedMetadataVisible = true
    private var configuredWidth: CGFloat = 0
    private var configuredHeight: CGFloat = 0

    /// Monotonic generation; every apply/prepare that kicks an async logo load
    /// tags it so only the newest requested logo for a slot can ever be assigned
    /// (never a stale/wrong item's art). Bumped on every `apply`.
    private var generation = 0

    /// Bounded prepared window: itemID → prepared model (+ warmed logo). Trimmed to
    /// the current slide plus its handed-in neighbours so it never grows unbounded.
    private var prepared: [String: HeroForegroundModel] = [:]
    /// Warmed logo images by itemID (raw cache decode), so a page can assign
    /// instantly instead of waiting on a fetch — the "prepare next/previous off
    /// transition" optimisation.
    private var warmedLogos: [String: UIImage] = [:]
    private var loadTasks: [String: Task<Void, Never>] = [:]

    /// Async `.logo` URL resolvers by itemID (mirrors the SwiftUI hero's
    /// `asyncFallbackURL`). Used when a slide has no baked `logoURL` — the common
    /// case — to resolve the real (series, for an episode) logo on demand.
    var logoFallbacks: [String: @Sendable () async -> URL?] = [:]

    func configure(width: CGFloat, height: CGFloat) {
        guard width != configuredWidth || height != configuredHeight else { return }
        configuredWidth = width
        configuredHeight = height
        view?.frame = CGRect(x: 0, y: 0, width: width, height: height)
        view?.setNeedsLayout()
    }

    /// Pre-prepares neighbour slides: caches their model and warms their logo image
    /// so the next/previous page is a HIT. Bounded to exactly the handed-in set
    /// (previous + next) plus the current slide.
    func prepare(_ neighbours: [HeroForegroundModel]) {
        var keep = Set(neighbours.map(\.itemID))
        if let applied = appliedModel { keep.insert(applied.itemID) }
        // Trim anything outside the current window.
        prepared = prepared.filter { keep.contains($0.key) }
        warmedLogos = warmedLogos.filter { keep.contains($0.key) }
        for (id, task) in loadTasks where !keep.contains(id) {
            task.cancel()
            loadTasks[id] = nil
        }
        for model in neighbours {
            prepared[model.itemID] = model
            warmLogo(for: model, generation: generation)
        }
    }

    /// Applies a slide's visuals in place. Emits a gated HIT/MISS marker (was the
    /// model already prepared?) and times the imperative update.
    func apply(_ model: HeroForegroundModel, metadataVisible: Bool) {
        guard let view else { return }
        let unchanged = appliedModel == model && appliedMetadataVisible == metadataVisible
        guard !unchanged else { return }

        let slideChanged = appliedModel?.itemID != model.itemID
        let hit = prepared[model.itemID] == model
        generation &+= 1
        let gen = generation
        appliedModel = model
        appliedMetadataVisible = metadataVisible
        prepared[model.itemID] = model

        HeroForegroundDiagnostics.emit(
            "apply id=\(model.itemID) slideChanged=\(slideChanged) \(hit ? "HIT" : "MISS")"
        )
        HeroForegroundDiagnostics.measure("update") {
            view.apply(
                model,
                logo: warmedLogos[model.itemID],
                metadataVisible: metadataVisible,
                slideChanged: slideChanged
            )
        }
        // Resolve/refresh the logo asynchronously if we don't already have it warm.
        // `warmLogo` self-guards on whether a primary URL or a fallback resolver
        // exists, so most slides (no baked `logoURL`) still resolve via the router.
        if warmedLogos[model.itemID] == nil {
            warmLogo(for: model, generation: gen, assignIfCurrent: true)
        }
    }

    /// Loads a slide's raw logo image off the shared artwork cache, generation- and
    /// identity-guarded so a slow load can never paint the wrong slide's logo. When
    /// the slide has no baked `logoURL` it first resolves one via the async `.logo`
    /// fallback (the router), exactly like the SwiftUI hero's `asyncFallbackURL`.
    private func warmLogo(for model: HeroForegroundModel, generation gen: Int, assignIfCurrent: Bool = false) {
        guard warmedLogos[model.itemID] == nil, loadTasks[model.itemID] == nil else { return }
        let id = model.itemID
        let primary = model.logoURL
        let fallback = logoFallbacks[id]
        guard primary != nil || fallback != nil else { return }
        loadTasks[id] = Task { [weak self] in
            var url = primary
            if url == nil, let fallback { url = await fallback() }
            guard let url else {
                await MainActor.run { self?.loadTasks[id] = nil }
                return
            }
            let image = await ArtworkImageCache.shared.image(for: url, variant: .original, background: true)
            await MainActor.run {
                guard let self else { return }
                self.loadTasks[id] = nil
                guard let image else { return }
                self.warmedLogos[id] = image
                // Only paint if this is still the fronted slide and no newer apply
                // has superseded us.
                if assignIfCurrent, self.appliedModel?.itemID == id, gen <= self.generation {
                    self.view?.setLogo(image, for: id)
                }
            }
        }
    }

    func cancelLoads() {
        for task in loadTasks.values { task.cancel() }
        loadTasks.removeAll()
    }
}
#endif
