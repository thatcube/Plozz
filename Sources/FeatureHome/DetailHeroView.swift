#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI
#if canImport(UIKit)
import UIKit
#endif

/// The top "hero" section of a detail page: a full-bleed backdrop with the
/// item's title, subtitle, ratings, overview, and an optional Play button.
///
/// It is intentionally stateless and driven entirely by `item`, so a parent can
/// swap which item it shows (series → focused season → focused episode) and the
/// whole hero animates to reflect the newly focused context.
struct DetailHeroView: View {
    let item: MediaItem
    /// The item whose artwork fills the backdrop. Defaults to `item`. A series
    /// page pins this to the series itself so the background stays a single,
    /// stable, high-quality image even as `item` (the focused season/episode)
    /// drives the logo, title, overview and Play button. Swapping the backdrop
    /// per focused episode reads as distracting flicker, so we don't.
    var backdropItem: MediaItem?
    let spoilerSettings: SpoilerSettings
    /// Title for the Play/Resume button, or `nil` to omit the button entirely
    /// (e.g. a season with no resolved episodes yet).
    let playTitle: String?
    let onPlay: (() -> Void)?
    /// When non-`nil`, a secondary "Trailer" button is shown next to Play.
    var onPlayTrailer: (() -> Void)? = nil

    /// The item supplying the backdrop artwork (the pinned series, when set).
    private var backdrop: MediaItem { backdropItem ?? item }

    var body: some View {
        let hideText = spoilerSettings.shouldHideText(for: item)
        let hideThumbnail = spoilerSettings.shouldHideThumbnail(for: item)
        ZStack(alignment: .bottomLeading) {
            FallbackAsyncImage(
                urls: [backdrop.heroBackdropURL, backdrop.backdropURL, backdrop.posterURL].compactMap { $0 },
                maxAspectRatio: 3.0
            ) {
                Rectangle().fill(.tertiary)
            }
            .frame(height: Self.heroHeight)
            .frame(maxWidth: .infinity)
            .clipped()
            .blur(radius: hideThumbnail && spoilerSettings.mode == .blur ? 40 : 0)
            .overlay(
                // Legibility scrim: darken the lower image so the title/overview
                // read clearly. It lives *under* the mask below, so it dissolves
                // away with the image and never tints the revealed background.
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: .clear, location: 0.5),
                        .init(color: .black.opacity(0.7), location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            // Dissolve the backdrop's own alpha to transparent over the lower
            // portion (top third stays a clean image) so the real `AppBackground`
            // shows straight through. Because that is the *same* fixed surface the
            // content below sits on, the transition is perfectly seamless — there
            // is no second colour to mismatch, so no hard line ever appears.
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .white, location: 0.0),
                        .init(color: .white, location: 0.33),
                        .init(color: .clear, location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            // Break out of the tvOS overscan safe area so the backdrop spans the
            // full screen edge to edge — across the top as well, otherwise the
            // top overscan inset shows through as a black bar above the artwork.
            .ignoresSafeArea(edges: [.top, .horizontal])

            VStack(alignment: .leading, spacing: 16) {
                if hideText {
                    titleText(hideText: hideText)
                } else {
                    HeroLogoArtwork(
                        primaryURL: item.logoURL,
                        asyncFallbackURL: tmdbLogoFallback
                    ) {
                        titleText(hideText: hideText)
                    }
                }
                if let subtitle = item.subtitle {
                    Text(subtitle).font(.title3).foregroundStyle(.secondary)
                }
                if !item.ratings.isEmpty {
                    RatingsBadgeRow(ratings: item.ratings)
                }
                if hideText {
                    Label("Overview hidden to avoid spoilers", systemImage: "eye.slash.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 1100, alignment: .leading)
                } else if let overview = item.overview {
                    Text(overview)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .frame(maxWidth: 1100, alignment: .leading)
                }
                if (playTitle != nil && onPlay != nil) || onPlayTrailer != nil {
                    HStack(spacing: 24) {
                        if let playTitle, let onPlay {
                            Button(action: onPlay) {
                                Label(playTitle, systemImage: "play.fill")
                                    .frame(minWidth: 260)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        if let onPlayTrailer {
                            Button(action: onPlayTrailer) {
                                Label("Trailer", systemImage: "film.fill")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.top, 8)
                }
            }
            .padding(PlozzTheme.Metrics.screenPadding)
        }
        // Cross-fade the hero text as the focused context changes, while the
        // backdrop swaps underneath it.
        .animation(.easeInOut(duration: 0.2), value: item.id)
    }

    /// The plain text title, used both under spoilers and as the fallback when no
    /// logo art can be resolved.
    private func titleText(hideText: Bool) -> some View {
        Text(hideText ? spoilerSettings.maskedTitle(for: item) : item.title)
            .font(.system(size: 64, weight: .bold))
    }

    /// Full-screen height for the backdrop so the hero reads as a cinematic,
    /// edge-to-edge image rather than a fixed-height banner. Falls back to a
    /// 1080p constant where UIKit isn't available (non-Apple toolchains/tests).
    private static var heroHeight: CGFloat {
        #if canImport(UIKit)
        return UIScreen.main.bounds.height
        #else
        return 1080
        #endif
    }

    /// Last-resort title art for the hero: look the show/movie up on TMDb and use
    /// its logo. TV uses the *series* title (never an episode name); inert when no
    /// TMDb token is configured.
    private var tmdbLogoFallback: (@Sendable () async -> URL?)? {
        let isTV: Bool
        let queryTitle: String
        let tmdbID: String?
        switch item.kind {
        case .movie, .video:
            isTV = false
            queryTitle = item.title
            tmdbID = item.providerIDs["Tmdb"]
        case .series:
            isTV = true
            queryTitle = item.title
            tmdbID = item.providerIDs["Tmdb"]
        case .season, .episode:
            isTV = true
            queryTitle = item.parentTitle ?? item.title
            // The item's own TMDb id is the episode/season, not the series, so
            // fall back to a title search for the show logo.
            tmdbID = nil
        case .folder, .collection, .unknown:
            return nil
        }
        let year = isTV ? nil : item.productionYear
        return {
            await TMDbArtworkResolver.shared.logoURL(
                title: queryTitle,
                year: year,
                isTV: isTV,
                tmdbID: tmdbID
            )
        }
    }
}

#endif
