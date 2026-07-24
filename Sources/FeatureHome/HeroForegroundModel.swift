import Foundation
import CoreModels

/// Pure, UIKit-free description of the Home **hero** *visual foreground* for one
/// slide, plus a pure builder that maps a ``MediaItem`` (and the view's already
/// resolved focus/selection/CTA state) into it.
///
/// This is the value layer of the env-gated (``HeroForegroundConfig``) imperative
/// UIKit foreground proof-of-concept. Keeping it Foundation-only means the whole
/// slide→visuals mapping is exhaustively unit-testable without a running view or a
/// simulator, and lets the persistent ``HeroForegroundUIView`` be a thin renderer
/// that only diffs and applies these values in place on a page — the whole point
/// of the redesign (no SwiftUI view-tree rebuild of the foreground per transition).
///
/// It deliberately carries only *non-secret* presentation data (titles, metadata,
/// SF Symbol names, progress fractions) — never tokens/urls-with-auth beyond the
/// public artwork logo URL the SwiftUI hero already exposes.
struct HeroForegroundModel: Equatable {
    /// Stable identity of the slide this model renders. Used by the renderer to
    /// tell a genuine slide change (wipe the visuals, animate the metadata fade)
    /// from a same-slide property refresh (selection move, watchlist flip).
    let itemID: String
    /// The show title. Always present as the reliable text baseline; drawn as a
    /// `UILabel` when no logo image is available (mirrors the SwiftUI hero's text
    /// fallback inside ``HeroLogoArtwork``).
    let title: String
    /// Optional provider/router logo art URL. The POC renderer loads the **raw**
    /// cached image (the CoreUI background-removal logo pipeline is internal), so a
    /// slide with a logo shows the image, otherwise the title text.
    let logoURL: URL?
    /// The dotted metadata line (year · runtime · genres), pre-joined with the
    /// hero's `  ·  ` separator, or `nil` when the slide has none.
    let metadataText: String?
    /// Content-rating badge text (e.g. `TV-14`), or `nil`.
    let ratingBadgeText: String?
    /// The hero's description line (already spoiler-gated by the caller): the
    /// item's short marketing tagline when it has one, otherwise its long
    /// overview as a fallback. `nil` only when neither exists / text is hidden.
    let overview: String?
    /// Every external rating available for the title, spoiler-gated by caller.
    let ratings: [ExternalRating]
    /// The visible action pills, left-to-right, exactly matching the SwiftUI
    /// hero's `buttons(for:)` order. Non-interactive here — the SwiftUI overlay
    /// owns focus/selection/dispatch — but their *visuals* (including the selected
    /// highlight) are drawn by the renderer.
    let pills: [Pill]
    /// Zero-based index of the currently selected pill (owned by the SwiftUI
    /// `selectedButton`); clamped to `pills` by the builder.
    let selectedIndex: Int
    /// Whether the hero currently holds focus. The selected pill only gets the
    /// bright treatment while this is `true` (matches `selected = focus != nil &&
    /// selectedButton == offset` in the SwiftUI hero).
    let heroFocused: Bool
    /// Paging-dot state, or `nil` for a single-slide carousel (no dots).
    let dots: Dots?

    /// One visible hero action pill's *visuals* only.
    struct Pill: Equatable {
        enum Kind: Equatable { case play, request, downloadStatus, moreInfo, watchlist, next }
        let kind: Kind
        /// Trailing text label (e.g. "Play", "Request", "Requested", the remaining
        /// time "20m", or the download "83%"), or `nil` for an icon-only pill.
        let text: String?
        /// SF Symbol name for the leading glyph, or `nil` for a text-only pill.
        let systemImage: String?
        /// In-progress fraction (`0...1`). When non-nil the renderer draws the shared
        /// inline progress bar (Play resume / active download) *between* the glyph and
        /// the trailing text — matching `PlayResumeButtonLabel` / `downloadStatusLabel`.
        let progress: Double?
        /// Whether this pill is the fallback primary CTA even while unfocused.
        var prominent: Bool = false
    }

    /// Paging-indicator state for the renderer (count + fronted index) plus the
    /// live auto-advance dwell so the active pill can fill left→right as a "time
    /// until next page" gauge, exactly like the SwiftUI hero. The exact windowing
    /// is computed by the renderer via ``HeroPagingDots`` so this stays a pure value.
    struct Dots: Equatable {
        let count: Int
        let index: Int
        /// Whether auto-advance is on (drives whether the active pill shows a moving
        /// gauge vs. a full static pill).
        var autoAdvance: Bool = false
        /// When the current slide's dwell started; the renderer interpolates the
        /// gauge from here across ``dwellDuration``. `nil` disables the gauge.
        var dwellStart: Date? = nil
        /// Total dwell seconds for the active slide.
        var dwellDuration: Double = 0
        /// When the dwell is frozen (user interacting / hero receded), the instant it
        /// froze at; the gauge holds here. `nil` when running.
        var pausedAt: Date? = nil
    }
}

/// Pure builder mapping a slide's ``MediaItem`` plus the SwiftUI hero's resolved
/// state into a ``HeroForegroundModel``. Every function here is deterministic and
/// side-effect free so the mapping can be unit-tested directly.
enum HeroForegroundModelBuilder {
    /// The dynamic per-pill inputs the SwiftUI hero has already resolved (watchlist
    /// membership, the availability-derived CTA). Passing these in keeps the
    /// builder pure — it never reaches into the action handler or Seerr state.
    struct PillInput: Equatable {
        let kind: HeroForegroundModel.Pill.Kind
        /// For `.watchlist`: whether the slide's watchlist *target* is favourited
        /// (drives filled vs outline bookmark). Ignored for other kinds.
        var isFavorite: Bool = false
        /// For `.play`: resume progress fraction, or `nil` when not resumable.
        var resumeProgress: Double? = nil
        /// For `.play`: whether the item is resumable (Play vs Resume label).
        var isResume: Bool = false
        /// For `.play`: the remaining-time text ("20m") shown in the resume form.
        /// When present alongside an in-range ``resumeProgress`` the pill renders the
        /// glyph + inline progress bar + this text (no "Resume" word), matching
        /// `PlayResumeButtonLabel`'s resume layout.
        var resumeRemainingText: String? = nil
        /// For `.play`: the episode the button plays, as `S{n}, E{m}` — appended to
        /// the plain label ("Play S21, E8") and prefixed to the resume trailing
        /// ("S5, E12 • 43m"). `nil` for movies/series.
        var seasonEpisodeText: String? = nil
        /// For `.downloadStatus`: active download fraction, or `nil` when the
        /// request is queued/searching (shows a plain "Requested" status).
        var downloadProgress: Double? = nil
        /// Makes a fallback action read as the primary CTA even while unfocused.
        var prominent: Bool = false
    }

    /// The `  ·  `-joined metadata line for a slide, or `nil` when empty.
    static func metadataText(for item: MediaItem) -> String? {
        var parts: [String] = []
        if let productionYear = item.productionYear {
            parts.append(String(productionYear))
        }
        parts.append(
            contentsOf: GenreDisplayFormatter.displayNames(
                for: Array(item.genres.prefix(3))
            )
        )
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    /// Hero certification label. Missing list-record metadata remains absent until
    /// Home's provider-detail enrichment supplies the real value; never fabricate NR
    /// when the full detail record may carry a certification.
    static func ratingBadgeText(for item: MediaItem) -> String? {
        item.ratingBadge?.label
    }

    /// The compact `S{season}, E{episode}` label used **inside Play/Resume buttons**
    /// to name the episode that the button will play. Comma-separated (vs the dotted
    /// subtitle form) to read tightly next to a title or a remaining-time. Episodes
    /// only — `nil` for movies/series so those buttons keep their plain label.
    static func seasonEpisodeButtonText(for item: MediaItem) -> String? {
        guard item.kind == .episode,
              let season = item.seasonNumber,
              let episode = item.episodeNumber else { return nil }
        return "S\(season), E\(episode)"
    }

    /// Text fallback used when logo artwork is unavailable. Episodes represent their
    /// series in the hero, so pair the series title with the separate S/E line rather
    /// than showing an episode title such as "Episode 1" above "S2 · E1".
    static func titleText(for item: MediaItem, maskedTitle: String?) -> String {
        if item.kind == .episode,
           let parentTitle = item.parentTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !parentTitle.isEmpty {
            return parentTitle
        }
        if let maskedTitle { return maskedTitle }
        return item.title
    }

    /// Maps one resolved ``PillInput`` to its rendered ``HeroForegroundModel/Pill``.
    static func pill(for input: PillInput) -> HeroForegroundModel.Pill {
        switch input.kind {
        case .play:
            // Resume form (matches PlayResumeButtonLabel): glyph + inline progress
            // bar + trailing text, with NO "Resume" word. The trailing is prefixed
            // with the episode ("S5, E12 • 43m") when known. Only when we have a
            // genuine in-range fraction *and* a remaining-time string; otherwise fall
            // back to the plain titled pill.
            if let p = input.resumeProgress, p > 0, p < 1, let remaining = input.resumeRemainingText {
                let trailing = input.seasonEpisodeText.map { "\($0) • \(remaining)" } ?? remaining
                return HeroForegroundModel.Pill(
                    kind: .play, text: trailing, systemImage: "play.fill", progress: p
                )
            }
            // Plain pill: base label with the episode appended when known
            // ("Play S21, E8"), else just "Resume"/"Play".
            let base = input.isResume ? "Resume" : "Play"
            let plain = input.seasonEpisodeText.map { "\(base) \($0)" } ?? base
            return HeroForegroundModel.Pill(
                kind: .play,
                text: plain,
                systemImage: "play.fill",
                progress: nil
            )
        case .request:
            return HeroForegroundModel.Pill(
                kind: .request, text: "Request", systemImage: "plus.circle",
                progress: nil, prominent: input.prominent
            )
        case .downloadStatus:
            if let progress = input.downloadProgress {
                let pct = Int((progress * 100).rounded())
                return HeroForegroundModel.Pill(
                    kind: .downloadStatus,
                    text: "\(pct)%",
                    systemImage: "arrow.down.circle",
                    progress: progress,
                    prominent: input.prominent
                )
            }
            return HeroForegroundModel.Pill(
                kind: .downloadStatus, text: "Requested", systemImage: "clock",
                progress: nil, prominent: input.prominent
            )
        case .moreInfo:
            return HeroForegroundModel.Pill(
                kind: .moreInfo,
                text: input.prominent ? "More Info" : nil,
                systemImage: "info.circle",
                progress: nil,
                prominent: input.prominent
            )
        case .watchlist:
            return HeroForegroundModel.Pill(
                kind: .watchlist,
                text: nil,
                systemImage: input.isFavorite ? "bookmark.fill" : "bookmark",
                progress: nil
            )
        case .next:
            return HeroForegroundModel.Pill(
                kind: .next, text: nil, systemImage: "chevron.right", progress: nil
            )
        }
    }

    /// Assembles the full slide model. `selectedIndex` is clamped defensively so a
    /// stale selection from a previous (differently-sized) slide can never point
    /// past the last pill — matching the SwiftUI hero's own clamping.
    static func model(
        item: MediaItem,
        overviewVisible: Bool,
        ratingsVisible: Bool = true,
        maskedTitle: String?,
        pillInputs: [PillInput],
        selectedIndex: Int,
        heroFocused: Bool,
        slideCount: Int,
        slideIndex: Int,
        dotsAutoAdvance: Bool = false,
        dotsDwellStart: Date? = nil,
        dotsDwellDuration: Double = 0,
        dotsPausedAt: Date? = nil
    ) -> HeroForegroundModel {
        let pills = pillInputs.map(pill(for:))
        let clamped = pills.isEmpty ? 0 : min(max(selectedIndex, 0), pills.count - 1)
        let dots: HeroForegroundModel.Dots? =
            slideCount > 1
            ? HeroForegroundModel.Dots(
                count: slideCount,
                index: slideIndex,
                autoAdvance: dotsAutoAdvance,
                dwellStart: dotsDwellStart,
                dwellDuration: dotsDwellDuration,
                pausedAt: dotsPausedAt
            )
            : nil
        return HeroForegroundModel(
            itemID: item.id,
            title: titleText(for: item, maskedTitle: maskedTitle),
            logoURL: item.logoURL,
            metadataText: metadataText(for: item),
            ratingBadgeText: ratingBadgeText(for: item),
            overview: overviewVisible
                ? HeroContentPolicy.homeDescription(
                    for: HeroPresentation(
                        item: item,
                        artworkStyle: .landscape,
                        surface: .home
                    )
                )
                : nil,
            ratings: ratingsVisible ? item.ratings : [],
            pills: pills,
            selectedIndex: clamped,
            heroFocused: heroFocused,
            dots: dots
        )
    }
}
