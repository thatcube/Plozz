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

    @discardableResult
    func recede() -> Bool {
        guard !isReceded else { return false }
        isReceded = true
        return true
    }

    @discardableResult
    func restore() -> Bool {
        guard isReceded else { return false }
        isReceded = false
        return true
    }
}

enum SeriesHeroRevealTransition {
    static var entrance: Animation { .smooth(duration: 0.7) }
}

enum SeriesEpisodeBrowserLayout {
    /// Pulls enough episode artwork above the fold to make the horizontal browser
    /// unmistakable while the full-screen backdrop still owns the resting page.
    /// Lowered from 420 to open ~40pt more breathing room between the hero action
    /// row and the episodes/Seasons below (the hero content is positioned
    /// independently, so it doesn't move).
    static let heroOverlap: CGFloat = 380
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
    /// Padding below the browser so the episode rail can still scroll to centre
    /// when nothing follows it.
    ///
    /// `showsTrailingContent` is any section beneath the browser — cast, Related,
    /// anything else — not the cast alone. That distinction became load-bearing
    /// once a page could have Related but no cast: a file-based share carries no
    /// cast, so the runway was still being added, and it landed as ~250pt of void
    /// above a Related row that was perfectly capable of providing the scroll room
    /// itself. The same show opened from a Plex copy has cast, took the zero-runway
    /// path, and looked right — which is why the two routes disagreed.
    static func trailingRunwayHeight(showsSeasons: Bool, showsTrailingContent: Bool) -> CGFloat {
        guard !showsTrailingContent else { return 0 }
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
    /// Whether any section follows the browser (cast, Related, …). Drives whether
    /// the trailing scroll runway is needed.
    let showsTrailingContent: Bool
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
                    showsTrailingContent: showsTrailingContent
                )
            )
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .environment(\.plozzMetrics, .standard)
    }
}

struct SeriesRecedeReveal<Content: View>: View {
    let recedeModel: SeriesHeroRecedeModel
    @ViewBuilder let content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let revealed = recedeModel.isReceded
        content()
            .opacity(revealed ? 1 : 0)
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.3),
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
