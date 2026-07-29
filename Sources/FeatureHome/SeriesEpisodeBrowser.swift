#if canImport(SwiftUI)
import SwiftUI
import Observation
import CoreModels
import CoreUI
import MetadataKit
#if canImport(UIKit)
import UIKit
#endif

/// Whether the series hero has receded behind the episode browser.
///
/// Deliberately a bare flag with no mutating helpers: the value is owned by a
/// single `.onScrollGeometryChange` observer on the page (see
/// `SeriesDetailView`), so nothing else may push it out of step with the actual
/// scroll offset. The earlier `recede()` / `restore()` pair existed for
/// focus-driven callers, and those callers were exactly what let the flag
/// disagree with the geometry.
@MainActor
@Observable
final class SeriesHeroRecedeModel {
    var isReceded = false
}

enum SeriesHeroRevealTransition {
    static var entrance: Animation { .easeInOut(duration: 0.2) }
}

enum SeriesEpisodeBrowserLayout {
    // MARK: The fixed stage
    //
    // Everything below follows one rule: **the layout is permanently in the
    // browsing arrangement, and the resting look is produced entirely by
    // render-only `.offset` transforms.**
    //
    // tvOS's focus engine scrolls a ScrollView to "reveal" whichever view just
    // took focus, using that view's LAYOUT frame. It is not optional and
    // `.scrollDisabled` does not suppress it (verified on device). Any design
    // where a focusable control's layout frame starts below the fold therefore
    // hands the page position to the focus engine — which is where the
    // overshoot on a fast UP, the half-receded hero, and the show-to-show
    // inconsistency all came from.
    //
    // So we never let that happen: the hero action row, the season bar and the
    // episode rail all have layout frames permanently inside the viewport, in
    // that vertical order. The engine has nothing to reveal, so it never
    // scrolls, so the transition is entirely ours to animate.

    /// The tvOS canvas height every constant here is derived from. Fixed rather
    /// than read from `UIScreen` so the arithmetic is inspectable in tests.
    static let screenHeightReference: CGFloat = 1080

    /// Distance the browser is pulled up into the hero, as a negative top
    /// padding. The column does not bottom out on the screen edge — that made
    /// the episode row sit uncomfortably low, with the focused card's captions
    /// jammed against the bottom. The receded stage is:
    ///
    ///     0    …  112    dead space (hero backdrop only)
    ///     112  …  186    hero action row (parked, faded out — never covered)
    ///      72  …  272    receded logo        ← RENDER ONLY, not in layout
    ///     272  …  360    season bar          ← the column starts here
    ///     360  …  880    episode rail
    ///     880  …  1080   breathing room
    ///
    /// Two hard rules keep tvOS's focus engine out of this:
    /// 1. Every focusable frame stays *inside* the viewport (ending short of the
    ///    bottom edge is fine; overflowing it is not, and so is sitting above the
    ///    top edge — an off-screen item simply cannot be focused).
    /// 2. No focusable frame may be covered by another view's layout frame, or
    ///    the engine treats it as unreachable. That is why the logo is an
    ///    overlay: as a column row it sat squarely on the hero action row.
    static let browserColumnTopInset: CGFloat = 272
    static let heroOverlap: CGFloat = screenHeightReference - browserColumnTopInset

    /// Render-only (drawn as an overlay above the column, see `SeriesEpisodeBrowser`).
    static let recededLogoHeight: CGFloat = 200
    /// A real, fixed viewport for the horizontal tab rail. Constraining the
    /// ScrollView itself removes its excess vertical proposal while keeping its
    /// rendered frame and tvOS focus-section geometry identical.
    static let seasonBarHeight: CGFloat = 88
    /// Softens the clipped boundary before the fixed season-request accessory.
    static let seasonRequestFadeWidth: CGFloat = 72
    /// Full height of an episode card: artwork + title + the focused card's
    /// 3-line synopsis. `heroOverlap` is derived from this so the browser column
    /// ends exactly at the bottom edge of the screen — the rail must be neither
    /// taller (an overflowing frame is what the focus engine scrolls to reveal)
    /// nor shorter (which clips the synopsis off the focused card).
    static let episodeRailHeight: CGFloat = 520

    /// How far the browser column is pushed back DOWN for the resting page, so
    /// only the top of the episode artwork peeks below the full-screen hero.
    /// Render-only, so the rail's focus frame stays on screen the whole time.
    /// Tracks `browserColumnTopInset`: the column's layout moved up, so the
    /// resting drop grows by the same amount to leave the peek identical.
    static let browserRestDrop: CGFloat = 568

    /// The hero action row's layout must sit above the season bar (or DOWN from
    /// Play could never reach it, and UP from a season chip could never reach
    /// the hero) — with real clearance, on screen, and uncovered. It parks at
    /// 112…186 and `heroContentRestDrop` pushes it visually back down to the
    /// lower third for the resting page.
    static let heroContentBottomLift: CGFloat = 860
    static let heroContentRestDrop: CGFloat = 583
    /// Zero — and that is a hard constraint, not a taste call. tvOS refuses to
    /// focus an item rendered entirely off-screen, so any lift large enough to
    /// clear the top edge makes UP from a season chip dead. The receded hero
    /// therefore *parks* at its layout position and disappears by fading
    /// instead. The visible motion is the rise/fall of `heroContentRestDrop`.
    static let heroContentRecedeLift: CGFloat = 0
    static let heroBackdropRecedeLift: CGFloat = 240

    /// Align the episode column's visible content—not the taller rail viewport—
    /// with screen center.
    static let focusedContentShift: CGFloat = 110
    static let focusAnchorY = episodeRailHeight / 2 - focusedContentShift

    static var screenHeight: CGFloat {
        #if canImport(UIKit)
        UIScreen.main.bounds.height
        #else
        1080
        #endif
    }

    /// No scroll runway is needed any more.
    ///
    /// It existed to give tvOS's focus reveal room to centre the episode row on
    /// a page that ended at the browser. The reveal no longer runs at all — the
    /// rail's layout frame is permanently on screen — so padding the page would
    /// only add dead space below the last row.
    static let trailingRunwayHeight: CGFloat = 0
}

/// One fixed-geometry stage for the receded series logo, Seasons, and Episodes.
/// Its static overlap makes the episode row peek below the resting full-screen
/// hero; one shared rail-center anchor moves this whole composition to its final
/// position when either Seasons or Episodes first receives focus.
struct SeriesEpisodeBrowser<SeasonContent: View, EpisodeContent: View>: View {
    let series: MediaItem
    let recedeModel: SeriesHeroRecedeModel
    let showsSeasons: Bool
    let focusAnchorID: String
    @ViewBuilder let seasonContent: () -> SeasonContent
    @ViewBuilder let episodeContent: () -> EpisodeContent

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsSeasons {
                seasonContent()
                    .plzGeoLog("seasonBar")
            }

            ZStack(alignment: .top) {
                episodeContent()
                    .frame(
                        height: SeriesEpisodeBrowserLayout.episodeRailHeight,
                        alignment: .top
                    )

                VStack(spacing: 0) {
                    Color.clear.frame(height: SeriesEpisodeBrowserLayout.focusAnchorY)
                    Color.clear
                        .frame(width: 1, height: 1)
                        .id(focusAnchorID)
                    Spacer(minLength: 0)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .frame(
                maxWidth: .infinity,
                minHeight: SeriesEpisodeBrowserLayout.episodeRailHeight,
                maxHeight: SeriesEpisodeBrowserLayout.episodeRailHeight,
                alignment: .topLeading
            )
            .plzGeoLog("rail")

        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        // Render-only, and that is the point: the receded logo used to be the
        // first row of this column, which put its LAYOUT frame directly on top
        // of the hero action row's. tvOS's focus engine treats a candidate
        // covered by another view as unreachable, so UP from a season chip
        // found nothing. As an overlay it draws in exactly the same place while
        // contributing no layout and no focus geometry at all.
        .overlay(alignment: .top) {
            SeriesRecededLogo(series: series, recedeModel: recedeModel)
                .frame(maxWidth: .infinity)
                .frame(height: SeriesEpisodeBrowserLayout.recededLogoHeight, alignment: .center)
                .offset(y: -SeriesEpisodeBrowserLayout.recededLogoHeight)
                .allowsHitTesting(false)
        }
        // The ONLY thing that moves for the resting page. A render-only
        // transform, so the season bar's and rail's layout/focus frames stay
        // inside the viewport at all times and tvOS never scrolls the page to
        // reveal them. The sections below keep their static layout position, so
        // this can't open a gap either.
        .offset(y: recedeModel.isReceded ? 0 : SeriesEpisodeBrowserLayout.browserRestDrop)
        .environment(\.plozzMetrics, .standard)
    }
}

struct SeriesRecedeReveal<Content: View>: View {
    let recedeModel: SeriesHeroRecedeModel
    /// Reveals the content regardless of the recede state. Used by the season bar,
    /// whose chips must never be invisible while they hold focus.
    var forceVisible: Bool = false
    @ViewBuilder let content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let revealed = recedeModel.isReceded || forceVisible
        content()
            .opacity(revealed ? 1 : 0)
            .animation(
                reduceMotion ? nil : SeriesHeroRevealTransition.entrance,
                value: revealed
            )
    }
}

private struct SeriesRecededLogo: View {
    let series: MediaItem
    let recedeModel: SeriesHeroRecedeModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let revealed = recedeModel.isReceded
        HeroLogoArtwork(
            references: series.artworkReferences(for: .logo),
            asyncFallbackURL: logoFallback,
            backgroundSample: backgroundSample,
            maxWidth: 620,
            maxHeight: 200,
            alignment: .center
        ) {
            Text(series.title)
                .font(.system(size: 64, weight: .bold))
                .lineLimit(2)
                .minimumScaleFactor(0.5)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 1200, alignment: .center)
        }
        .frame(width: 620, height: 200, alignment: .center)
        .opacity(revealed ? 1 : 0)
        .offset(y: revealed || reduceMotion ? 0 : 80)
        .accessibilityHidden(!revealed)
        // Deliberately no `.animation` modifier: the logo has to arrive *with*
        // the hero's departure, so it inherits the single ambient transaction the
        // recede observer opens instead of running on its own clock.
        // `reduceMotion` still gets a static presentation via the offset above.
    }

    private var logoFallback: (@Sendable () async -> URL?)? {
        let source = series
        return {
            await ArtworkRouter.shared.artworkURL(.logo, for: source)
        }
    }

    private var backgroundSample: (@Sendable () async -> HeroBackgroundSample?)? {
        #if canImport(UIKit)
        let urls = [series.heroBackdropURL, series.backdropURL].compactMap { $0 }
        let source = series
        return {
            if let sample = await HeroBackgroundSampler.sample(urls: urls) { return sample }
            if let resolved = await ArtworkRouter.shared.artworkURL(.hero, for: source),
               let sample = await HeroBackgroundSampler.sample(urls: [resolved]) {
                return sample
            }
            if let poster = source.posterURL {
                return await HeroBackgroundSampler.sample(urls: [poster])
            }
            return nil
        }
        #else
        return nil
        #endif
    }
}
#endif
