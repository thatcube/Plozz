#if canImport(SwiftUI)
import SwiftUI
import Observation
import CoreModels
import CoreUI
import MetadataKit
#if canImport(UIKit)
import UIKit
#endif

@MainActor
@Observable
final class SeriesHeroRecedeModel {
    var isReceded = false

    func recede() {
        isReceded = true
    }

    func restore() {
        isReceded = false
    }
}

enum SeriesHeroRevealTransition {
    static var entrance: Animation { .smooth(duration: 0.7) }
}

enum SeriesEpisodeBrowserLayout {
    /// Pulls enough episode artwork above the fold to make the horizontal browser
    /// unmistakable while the full-screen backdrop still owns the resting page.
    static let heroOverlap: CGFloat = 420
    /// The matching series-only lift for the bottom-anchored hero content. Keeping
    /// this static preserves immutable focus geometry and leaves a clean gap between
    /// the hero action row and Seasons despite the deeper browser overlap.
    static let heroContentBottomLift: CGFloat = 160
    static let recededLogoHeight: CGFloat = 200
    /// A real, fixed viewport for the horizontal tab rail. Constraining the
    /// ScrollView itself removes its excess vertical proposal while keeping its
    /// rendered frame and tvOS focus-section geometry identical.
    static let seasonBarHeight: CGFloat = 88
    /// Softens the clipped boundary before the fixed season-request accessory.
    static let seasonRequestFadeWidth: CGFloat = 72
    /// Prevents the episode rail from absorbing the full-screen stage's surplus
    /// height while preserving normal size proposals for every card.
    static let episodeRailHeight: CGFloat = 520
    /// Align the episode column's visible content—not the taller rail viewport—
    /// with screen center.
    static let focusedContentShift: CGFloat = 110
    static let focusAnchorY = episodeRailHeight / 2 - focusedContentShift

    static var minimumNoCastStageHeight: CGFloat {
        #if canImport(UIKit)
        UIScreen.main.bounds.height - focusedContentShift
        #else
        1080 - focusedContentShift
        #endif
    }

    /// Cast already provides enough real trailing content to center the browser;
    /// only a no-Cast page needs invisible runway to reach the same position.
    static func trailingRunwayHeight(showsSeasons: Bool, showsCast: Bool) -> CGFloat {
        guard !showsCast else { return 0 }
        let groupedHeight = recededLogoHeight
            + (showsSeasons ? seasonBarHeight : 0)
            + episodeRailHeight
        return max(minimumNoCastStageHeight - groupedHeight, 0)
    }
}

/// One fixed-geometry stage for the receded series logo, Seasons, and Episodes.
/// Its static overlap makes the episode row peek below the resting full-screen
/// hero; one shared rail-center anchor moves this whole composition to its final
/// position when either Seasons or Episodes first receives focus.
struct SeriesEpisodeBrowser<SeasonContent: View, EpisodeContent: View>: View {
    let series: MediaItem
    let recedeModel: SeriesHeroRecedeModel
    let showsSeasons: Bool
    let showsCast: Bool
    let focusAnchorID: String
    @ViewBuilder let seasonContent: () -> SeasonContent
    @ViewBuilder let episodeContent: () -> EpisodeContent

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SeriesRecededLogo(series: series, recedeModel: recedeModel)
                .frame(maxWidth: .infinity)
                .frame(height: SeriesEpisodeBrowserLayout.recededLogoHeight, alignment: .center)

            if showsSeasons {
                seasonContent()
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

            Color.clear.frame(
                height: SeriesEpisodeBrowserLayout.trailingRunwayHeight(
                    showsSeasons: showsSeasons,
                    showsCast: showsCast
                )
            )
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .environment(\.plozzMetrics, .standard)
    }
}

private struct SeriesRecededLogo: View {
    let series: MediaItem
    let recedeModel: SeriesHeroRecedeModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let revealed = recedeModel.isReceded
        HeroLogoArtwork(
            primaryURL: series.logoURL,
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
        .offset(y: revealed ? 0 : 260)
        .accessibilityHidden(!revealed)
        .animation(
            reduceMotion
                ? nil
                : (revealed
                    ? SeriesHeroRevealTransition.entrance
                    : .easeOut(duration: 0.22)),
            value: revealed
        )
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
