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
    /// Technical badges to show when the focused item carries none of its own —
    /// a series or season hero has no media file, so the parent derives a
    /// representative set from the loaded episodes (best resolution/HDR/audio)
    /// and passes it here so a show still advertises 4K/Dolby Vision/Atmos.
    var fallbackTechnicalBadges: [MediaBadge] = []
    /// When provided, the hero's Play button binds to this focus state (as
    /// `true`), letting a parent give Play initial focus — used when a page is
    /// opened targeting a specific episode so focus lands on Play at the top
    /// rather than down in the episode row.
    var playButtonFocus: FocusState<Bool>.Binding? = nil

    /// The item supplying the backdrop artwork (the pinned series, when set).
    private var backdrop: MediaItem { backdropItem ?? item }

    /// The capability badges shown above the ratings: the content-rating
    /// certificate (e.g. `TV-14`) leading, then resolution/HDR/audio badges.
    /// When the focused item is an episode without its own certificate, the
    /// rating falls back to the backdrop item (the series), so a show's TV
    /// rating still shows while scrubbing episodes — matching Apple TV.
    private var featureBadges: [MediaBadge] {
        let rating = item.ratingBadge ?? backdrop.ratingBadge
        // Prefer the focused item's own tech badges; fall back to the derived
        // series-level set for a series/season hero (or an episode whose stream
        // info hasn't loaded), so tech badges are present on every kind.
        let ownTech = item.technicalBadges
        let tech = ownTech.isEmpty ? fallbackTechnicalBadges : ownTech
        return (rating.map { [$0] } ?? []) + tech
    }

    /// External ratings to show. Falls back to the backdrop item (the series)
    /// when the focused item (an episode) carries none of its own, so a show's
    /// rating stays visible while scrubbing episodes.
    private var heroRatings: [ExternalRating] {
        item.ratings.isEmpty ? backdrop.ratings : item.ratings
    }

    /// True when `subtitle` is just the production year — the richer metadata
    /// line below already opens with the year, so we drop the duplicate.
    private func isYearOnlySubtitle(_ subtitle: String) -> Bool {
        guard let year = item.productionYear else { return false }
        return subtitle == String(year)
    }

    var body: some View {
        let hideText = spoilerSettings.shouldHideText(for: item)
        let hideThumbnail = spoilerSettings.shouldHideThumbnail(for: item)
        ZStack(alignment: .bottomLeading) {
            FallbackAsyncImage(
                urls: [backdrop.heroBackdropURL, backdrop.backdropURL, backdrop.posterURL].compactMap { $0 },
                maxAspectRatio: 3.0,
                asyncFallbackURL: tmdbBackdropFallback
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

            VStack(alignment: .leading, spacing: 12) {
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
                if let subtitle = item.subtitle, !isYearOnlySubtitle(subtitle) {
                    Text(subtitle)
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                let metadata = item.metadataComponents()
                if !metadata.isEmpty {
                    Text(metadata.joined(separator: "  ·  "))
                        .font(.system(size: 23, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                if !hideText, let tagline = item.tagline {
                    Text(tagline)
                        .font(.system(size: 24, weight: .medium))
                        .italic()
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: 960, alignment: .topLeading)
                }
                if !featureBadges.isEmpty {
                    MediaBadgeRow(badges: featureBadges)
                }
                if !heroRatings.isEmpty {
                    RatingsBadgeRow(ratings: heroRatings)
                }
                if hideText {
                    Label("Overview hidden to avoid spoilers", systemImage: "eye.slash.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 960, alignment: .topLeading)
                } else if let overview = item.overview {
                    Text(overview)
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                        .lineSpacing(2)
                        // Reserve three lines of height even when the text is
                        // shorter, so swapping the focused item never makes the
                        // controls below jump up and down.
                        .lineLimit(3, reservesSpace: true)
                        .frame(maxWidth: 960, alignment: .topLeading)
                }
                if (playTitle != nil && onPlay != nil) || onPlayTrailer != nil {
                    HStack(spacing: 24) {
                        if let playTitle, let onPlay {
                            playButton(title: playTitle, action: onPlay)
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
            .padding(.vertical, PlozzTheme.Metrics.screenPadding)
            .padding(.trailing, PlozzTheme.Metrics.screenPadding)
            .padding(.leading, PlozzTheme.Metrics.heroLeadingPadding)
        }
        // Cross-fade the hero text as the focused context changes, while the
        // backdrop swaps underneath it.
        .animation(.easeInOut(duration: 0.2), value: item.id)
    }

    /// The hero Play button. Extracted so the optional initial-focus binding can
    /// be applied to it conditionally (a `nil` binding leaves default focus
    /// behaviour untouched).
    @ViewBuilder
    private func playButton(title: String, action: @escaping () -> Void) -> some View {
        let button = Button(action: action) {
            Label(title, systemImage: "play.fill")
                .frame(minWidth: 260)
        }
        .buttonStyle(.borderedProminent)
        if let playButtonFocus {
            button.focused(playButtonFocus, equals: true)
        } else {
            button
        }
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

    /// Last-resort backdrop art for the hero: look the show/movie up on TMDb and
    /// use a wide fanart image. Many anime (via Shoko/AniDB) ship no backdrop, so
    /// this fills the otherwise-empty hero. Uses the *backdrop* item (the series,
    /// when pinned) and its TMDb id when that id refers to the show itself; for an
    /// episode/season backdrop it queries by series title. Inert without a token.
    private var tmdbBackdropFallback: (@Sendable () async -> URL?)? {
        let source = backdrop
        let isTV: Bool
        let queryTitle: String
        let tmdbID: String?
        switch source.kind {
        case .movie, .video:
            isTV = false
            queryTitle = source.title
            tmdbID = source.providerIDs["Tmdb"]
        case .series:
            isTV = true
            queryTitle = source.title
            tmdbID = source.providerIDs["Tmdb"]
        case .season, .episode:
            isTV = true
            queryTitle = source.parentTitle ?? source.title
            // The item's own TMDb id is the episode/season, not the series.
            tmdbID = nil
        case .folder, .collection, .unknown:
            return nil
        }
        guard !queryTitle.isEmpty || (tmdbID?.isEmpty == false) else { return nil }
        let year = isTV ? nil : source.productionYear
        return {
            await TMDbArtworkResolver.shared.backdropURL(
                title: queryTitle,
                year: year,
                isTV: isTV,
                tmdbID: tmdbID
            )
        }
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
