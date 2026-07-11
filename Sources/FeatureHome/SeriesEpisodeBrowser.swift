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

enum SeriesEpisodeBrowserLayout {
    /// Pulls enough episode artwork above the fold to make the horizontal browser
    /// unmistakable while the full-screen backdrop still owns the resting page.
    static let heroOverlap: CGFloat = 540
    /// The matching series-only lift for the bottom-anchored hero content. Keeping
    /// this static preserves immutable focus geometry and leaves a clean gap between
    /// the hero action row and Seasons despite the deeper browser overlap.
    static let heroContentBottomLift: CGFloat = 240
    /// A real, fixed viewport for the horizontal tab rail. Constraining the
    /// ScrollView itself removes its excess vertical proposal while keeping its
    /// rendered frame and tvOS focus-section geometry identical.
    static let seasonBarHeight: CGFloat = 88
    /// The browser owns one complete viewport before Cast/extras begin. Besides
    /// creating a deliberate episode-browsing page, the unused portion after the
    /// grouped browser is nonfocusable trailing runway. It centers the rail
    /// identically whether extras exist or not without separating Seasons from
    /// Episodes.
    static var stageHeight: CGFloat {
        #if canImport(UIKit)
        UIScreen.main.bounds.height
        #else
        1080
        #endif
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
    let focusAnchorID: String
    @ViewBuilder let seasonContent: () -> SeasonContent
    @ViewBuilder let episodeContent: () -> EpisodeContent

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SeriesRecededLogo(series: series, recedeModel: recedeModel)
                .frame(maxWidth: .infinity)
                .frame(height: 200, alignment: .center)

            if showsSeasons {
                seasonContent()
            }

            episodeContent()
                // Reserve the complete standard episode-column rail even while a
                // season's episodes are loading. Centering this stable wrapper gives
                // Seasons and Episodes the exact same vertical destination.
                .frame(minHeight: 520, alignment: .top)
                .id(focusAnchorID)
        }
        .frame(
            maxWidth: .infinity,
            minHeight: SeriesEpisodeBrowserLayout.stageHeight,
            alignment: .topLeading
        )
        .environment(\.plozzMetrics, .standard)
    }
}

private struct SeriesRecededLogo: View {
    let series: MediaItem
    let recedeModel: SeriesHeroRecedeModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HeroLogoArtwork(
            primaryURL: series.logoURL,
            asyncFallbackURL: logoFallback,
            backgroundSample: backgroundSample,
            maxWidth: 620,
            maxHeight: 200
        ) {
            Text(series.title)
                .font(.system(size: 64, weight: .bold))
                .lineLimit(2)
                .minimumScaleFactor(0.5)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 1200, alignment: .center)
        }
        .frame(width: 620, height: 200, alignment: .center)
        .opacity(recedeModel.isReceded ? 1 : 0)
        .offset(y: recedeModel.isReceded ? 0 : -220)
        .animation(
            reduceMotion ? nil : .smooth(duration: 0.65),
            value: recedeModel.isReceded
        )
        .accessibilityHidden(!recedeModel.isReceded)
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
