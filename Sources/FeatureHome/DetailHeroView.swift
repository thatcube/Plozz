#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI
import MetadataKit
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
    /// Fraction of the screen height the hero backdrop occupies. Defaults to a
    /// full-screen cinematic hero (`1.0`); a TV show shrinks this (e.g. `0.8`) so
    /// the season tabs and episode row peek above the fold, signalling there's
    /// more to scroll to.
    var heroHeightFraction: CGFloat = 1.0
    let spoilerSettings: SpoilerSettings
    /// Title for the Play/Resume button, or `nil` to omit the button entirely
    /// (e.g. a season with no resolved episodes yet).
    let playTitle: String?
    let onPlay: (() -> Void)?
    /// When provided (`0..<1`), a thin watched-progress bar is shown inside the
    /// Play button, between the play icon and the remaining-time line.
    var playProgress: Double? = nil
    /// When provided, a "… left" remaining-time line is shown inside the Play
    /// button, after the progress bar.
    var playRemainingText: String? = nil
    /// When provided, a secondary "Trailer" button is shown next to Play.
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

    /// Local focus state of the Play button, so the inline resume progress bar
    /// can flip its colours to stay visible against the button's focused (white)
    /// vs unfocused (dark) background.
    @FocusState private var playButtonHasFocus: Bool

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
                urls: [backdrop.heroBackdropURL, backdrop.backdropURL].compactMap { $0 },
                maxAspectRatio: 3.0,
                asyncFallbackURL: tmdbBackdropFallback
            ) {
                Rectangle().fill(.tertiary)
            }
            .frame(height: Self.screenHeight * heroHeightFraction)
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
                        .lineLimit(1)
                        .frame(maxWidth: 1200, alignment: .leading)
                }
                let metadata = item.metadataComponents()
                if !metadata.isEmpty {
                    Text(metadata.joined(separator: "  ·  "))
                        .font(.system(size: 23, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: 1200, alignment: .leading)
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
                if !heroRatings.isEmpty && !spoilerSettings.shouldHideRatings(for: item) {
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
                            .modifier(HeroButtonStyle(prominent: false))
                        }
                    }
                    .padding(.top, 8)
                    // Span the full width and make the action row one focus section.
                    // Full width is what lets "up" from a season parked far to the
                    // right reliably land here — a narrow section only aligns with
                    // the left-most seasons. Keeps working as more buttons are added.
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .focusSection()
                }
            }
            .padding(.vertical, PlozzTheme.Metrics.screenPadding)
            .padding(.trailing, PlozzTheme.Metrics.screenPadding)
            .padding(.leading, PlozzTheme.Metrics.heroLeadingPadding)
            // Pin the content column to the *proposed* width (the safe viewport),
            // never a hard-coded panel width, so no inner row (a long title, a wide
            // badge/ratings strip, an oversized logo) can report a width greater
            // than the viewport. Using `.infinity` reports the proposed width and
            // caps over-wide children to it; a fixed 1920 would exceed the tvOS
            // safe area (~1740) and itself cause the page to pan.
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Cross-fade the hero text as the focused context changes, while the
        // backdrop swaps underneath it.
        .animation(.easeInOut(duration: 0.2), value: item.id)
    }

    /// The hero Play button. Extracted so the optional initial-focus binding can
    /// be applied to it conditionally (a `nil` binding leaves default focus
    /// behaviour untouched). When the resume target is partially watched the
    /// label becomes `▶  [progress bar]  … left`, keeping the button's normal
    /// height; otherwise it's the plain `▶  Play/Resume`.
    @ViewBuilder
    private func playButton(title: String, action: @escaping () -> Void) -> some View {
        let button = Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: "play.fill")
                if let playRemainingText, let playProgress, playProgress > 0, playProgress < 1 {
                    resumeProgressCapsule(progress: playProgress)
                    Text(playRemainingText)
                } else {
                    Text(title)
                }
            }
            .frame(minWidth: 260)
        }
        .modifier(HeroButtonStyle(prominent: true))
        .focused($playButtonHasFocus)

        if let playButtonFocus {
            button.focused(playButtonFocus, equals: true)
        } else {
            button
        }
    }

    /// The thin watched-progress bar shown inside the Play button between the
    /// play icon and the "… left" line. Its colours flip with the button's focus
    /// state — light fill on the dark unfocused button, dark fill on the white
    /// focused button — so it stays clearly visible either way.
    private func resumeProgressCapsule(progress: Double) -> some View {
        let onLight = playButtonHasFocus
        let track = onLight ? Color.black.opacity(0.22) : Color.white.opacity(0.32)
        let fill = onLight ? Color.black.opacity(0.85) : Color.white
        let width: CGFloat = 150
        return Capsule()
            .fill(track)
            .frame(width: width, height: 6)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(fill)
                    .frame(width: max(8, width * progress), height: 6)
            }
            .animation(.easeInOut(duration: 0.2), value: onLight)
    }

    /// The plain text title, used both under spoilers and as the fallback when no
    /// logo art can be resolved. Width is capped (and the text wraps/scales) so a
    /// very long title can never render as a single line wider than the screen —
    /// which would blow the hero's content past the viewport and shove the whole
    /// page (title + focusable buttons) off the left edge.
    private func titleText(hideText: Bool) -> some View {
        Text(hideText ? spoilerSettings.maskedTitle(for: item) : item.title)
            .font(.system(size: 64, weight: .bold))
            .lineLimit(2)
            .minimumScaleFactor(0.5)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: 1200, alignment: .leading)
    }

    /// Full screen height, the basis for the backdrop's height (scaled by
    /// `heroHeightFraction`). Falls back to a 1080p constant where UIKit isn't
    /// available (non-Apple toolchains/tests).
    private static var screenHeight: CGFloat {
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
        switch source.kind {
        case .folder, .collection, .unknown:
            return nil
        default:
            break
        }
        return {
            await ArtworkRouter.shared.artworkURL(.hero, for: source)
        }
    }

    /// Last-resort title art for the hero: look the show/movie up on TMDb and use
    /// its logo. TV uses the *series* title (never an episode name); inert when no
    /// TMDb token is configured.
    private var tmdbLogoFallback: (@Sendable () async -> URL?)? {
        let source = item
        switch source.kind {
        case .folder, .collection, .unknown:
            return nil
        default:
            break
        }
        return {
            await ArtworkRouter.shared.artworkURL(.logo, for: source)
        }
    }
}

/// Applies the native Liquid Glass button style to the hero's action buttons on
/// OS versions that ship it (tvOS 26+), falling back to the classic bordered
/// styles below that. `prominent` picks the tinted primary glass (Play) versus
/// the lighter clear glass (secondary actions like Trailer).
private struct HeroButtonStyle: ViewModifier {
    let prominent: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(tvOS 26.0, *) {
            if prominent {
                content.buttonStyle(.glassProminent)
            } else {
                content.buttonStyle(.glass)
            }
        } else {
            if prominent {
                content.buttonStyle(.borderedProminent)
            } else {
                content.buttonStyle(.bordered)
            }
        }
    }
}

#endif
