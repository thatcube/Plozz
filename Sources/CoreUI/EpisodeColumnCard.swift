#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import MetadataKit

/// The fixed standard-size, borderless episode column used only on series detail.
///
/// `Equatable` so callers can wrap it in `.equatable()`, and that is a measured
/// requirement rather than a nicety. The card stores its `action` closure, and
/// closures never compare equal, so SwiftUI's structural check on the view value
/// always failed: EVERY card in the rail re-evaluated its body whenever the
/// parent did. `Self._printChanges()` on an A12 Apple TV recorded 2550
/// `@self changed` rebuilds against only 141 real focus changes — an 18×
/// amplification — and most of them fired during hero transitions, when nothing
/// about any card had changed at all.
///
/// Comparing the inputs is sound because everything the card draws is derived
/// from them: `presentation` is built from exactly this pair, and the body's
/// remaining direct reads are all off `item`. Focus, the synopsis animation and
/// environment values are separate graph dependencies, so they still invalidate
/// the body normally — `.equatable()` only short-circuits the *value* check.
public struct EpisodeColumnCard: View, Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item == rhs.item && lhs.spoilerSettings == rhs.spoilerSettings
    }

    public static let artworkSize = CGSize(width: 480, height: 270)
    public static let sideMargin: CGFloat = 8
    public static let slotWidth = artworkSize.width + sideMargin * 2

    private let item: MediaItem
    private let spoilerSettings: SpoilerSettings
    private let presentation: EpisodeColumnPresentation
    private let action: () -> Void

    @FocusState private var isFocused: Bool
    @State private var synopsisVisible = false
    @State private var synopsisAtRest = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.plozzWatchStatusIndicator) private var watchStatusIndicator
    @Environment(\.themePalette) private var palette

    private let metrics = PlozzMetrics.standard

    public init(
        item: MediaItem,
        spoilerSettings: SpoilerSettings = .default,
        action: @escaping () -> Void
    ) {
        self.item = item
        self.spoilerSettings = spoilerSettings
        self.presentation = EpisodeColumnPresentation(
            item: item,
            spoilerSettings: spoilerSettings
        )
        self.action = action
    }

    public var body: some View {
        let _ = plozzTraceBodyChanges { Self._printChanges() }
        VStack(alignment: .leading, spacing: 0) {
            artwork
                .frame(width: Self.artworkSize.width, height: Self.artworkSize.height)
                // A not-yet-aired episode reads as unavailable rather than merely
                // unwatched: desaturated and dimmed, with the air date on the
                // artwork so the card says what it's waiting for.
                .saturation(presentation.isUpcoming ? 0 : 1)
                .opacity(presentation.isUpcoming ? 0.05 : 1)
                // The artwork is nearly transparent, so without an opaque surface
                // beneath it the focus backing shows through and washes the card out
                // further the moment it takes focus. This keeps the slot's own
                // surface — and the focus outline's contrast — constant.
                .background {
                    if presentation.isUpcoming {
                        palette.cardSurface
                    }
                }
                .overlay {
                    if presentation.isUpcoming, let air = item.upcomingReleaseText {
                        // Spelled out rather than a bare date: "Releases Friday"
                        // can't be mistaken for an air date already passed.
                        Label(air, systemImage: "clock")
                            .font(.system(size: 21, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                }
                .overlay {
                    if presentation.artworkTreatment != .blurred {
                        ResumeChipOverlay(item: item)
                            // Settles the chip's white at rest, full strength on
                            // focus. No-op off tvOS.
                            .plozzChromeFocused(isFocused)
                    }
                }
                .overlay(alignment: .topTrailing) { statusIndicator }
                .clipShape(RoundedRectangle(
                    cornerRadius: metrics.landscapeCardCornerRadius,
                    style: .continuous
                ))
                .plozzMediaEdge(cornerRadius: metrics.landscapeCardCornerRadius)
                .plozzFocusHalo(
                    cornerRadius: metrics.landscapeCardCornerRadius,
                    focusScale: reduceMotion ? 1 : PlozzTheme.Metrics.mediumFocusedCardScale,
                    isFocused: isFocused
                )

            VStack(alignment: .leading, spacing: 0) {
                presentation.titleLine
                    .font(.system(size: metrics.cardTitleFontSize, weight: .semibold))
                    .foregroundStyle(presentation.isUpcoming ? .secondary : .primary)
                    .lineLimit(1)
                    .padding(.top, metrics.landscapeCaptionTopSpacing + metrics.focusCaptionPush)

                SpoilerSafeOverviewText(
                    overview: presentation.overviewTreatment == .blurred
                        ? item.overview
                        : presentation.visibleOverview,
                    hidesSpoilers: presentation.overviewTreatment == .blurred
                        || presentation.overviewTreatment == .placeholder,
                    mode: spoilerSettings.mode,
                    lineCount: 3,
                    fontSize: 20,
                    maxWidth: Self.artworkSize.width
                )
                .opacity(synopsisVisible ? 1 : 0)
                .animation(
                    reduceMotion ? nil : .easeOut(duration: 0.12),
                    value: synopsisVisible
                )
                .offset(y: reduceMotion || synopsisAtRest ? 0 : -metrics.focusCaptionPush)
                .animation(
                    reduceMotion ? nil : .smooth(duration: 0.28),
                    value: synopsisAtRest
                )
                .padding(.top, 10)
            }
            .offset(y: reduceMotion || isFocused ? 0 : -metrics.focusCaptionPush)
        }
        .frame(width: Self.artworkSize.width, alignment: .leading)
        .padding(.horizontal, Self.sideMargin)
        .focusableCard(
            isFocused: $isFocused,
            cornerRadius: metrics.landscapeCardCornerRadius,
            action: action
        )
        .compositingGroup()
        .plozzCardFocusTransition(isFocused: isFocused, animates: !reduceMotion)
        .task(id: synopsisTaskID) {
            synopsisVisible = false
            synopsisAtRest = false
            guard isFocused else { return }
            if reduceMotion {
                synopsisVisible = true
                synopsisAtRest = true
                return
            }
            try? await Task.sleep(for: .milliseconds(110))
            guard !Task.isCancelled else { return }
            synopsisVisible = true
            synopsisAtRest = true
        }
        .mediaItemContextMenu(for: item)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
    }

    private var synopsisTaskID: SynopsisTaskID {
        SynopsisTaskID(isFocused: isFocused, reduceMotion: reduceMotion)
    }

    private struct SynopsisTaskID: Hashable {
        let isFocused: Bool
        let reduceMotion: Bool
    }

    @ViewBuilder
    private var artwork: some View {
        switch presentation.artworkTreatment {
        case .visible:
            realArtwork
        case .blurred:
            realArtwork.blur(radius: 28)
        case .placeholder:
            placeholderArtwork
        }
    }

    private var realArtwork: some View {
        FallbackAsyncImage(
            references: item.artworkReferences(for: .episodeThumbnail),
            variant: .landscapeCard,
            asyncFallbackURL: asyncArtworkFallback
        ) {
            neutralPlaceholder
        }
    }

    /// Spoiler-safe art for `.placeholder` mode: only ever **series-level** art,
    /// never the real episode frame.
    ///
    /// Mirrors `realArtwork`'s shape — server art first, then an `ArtworkRouter`
    /// last resort. Previously this read a single URL and fell straight through to
    /// a grey box, and that URL (`fallbackArtworkURL`) was only ever populated by
    /// Jellyfin, so on Plex and direct shares every hidden episode rendered blank.
    ///
    /// Nothing here may reach for `posterURL`/`backdropURL`: on Jellyfin those are
    /// the episode's own images, which is exactly what this mode hides.
    private var placeholderArtwork: some View {
        FallbackAsyncImage(
            references: placeholderArtworkReferences,
            variant: .landscapeCard,
            asyncFallbackURL: placeholderArtworkFallback
        ) {
            neutralPlaceholder
        }
    }

    /// Server-supplied series art for a wide card: the show's backdrop, with its
    /// vertical poster as a last resort — a cropped poster still identifies the
    /// show, and a blank card does not.
    private var placeholderArtworkReferences: [ArtworkReference] {
        // Only the explicitly series-scoped local selection. Going through
        // `artworkReferences(for: .seriesPoster)` would append that placement's
        // legacy ladder, which ends in the episode's own `posterURL`.
        let localSeriesArt = item.artworkSelections
            .first(where: { $0.placement == .seriesPoster })?
            .references ?? []
        let remote = [item.fallbackArtworkURL, item.seriesPosterURL]
            .compactMap { $0.map(ArtworkReference.remote) }
        var seen = Set<ArtworkReference>()
        return (remote + localSeriesArt).filter { seen.insert($0).inserted }
    }

    /// Last-resort series art from the metadata router. Asks only for a
    /// series-scoped hero against a synthesized series item — never `.thumbnail`,
    /// which resolves the episode's own still.
    private var placeholderArtworkFallback: (@Sendable () async -> URL?)? {
        let seriesItem = PosterCardView.seriesArtworkItem(for: item)
        return {
            await ArtworkRouter.shared.artworkURL(.hero, for: seriesItem)
        }
    }

    private var neutralPlaceholder: some View {
        MediaArtworkPlaceholder()
    }

    private var asyncArtworkFallback: (@Sendable () async -> URL?)? {
        let snapshot = item
        return {
            if let still = await ArtworkRouter.shared.artworkURL(.thumbnail, for: snapshot) {
                return still
            }
            return await ArtworkRouter.shared.artworkURL(.hero, for: snapshot)
                ?? snapshot.fallbackArtworkURL
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        // An unaired episode has no watch state to report, so neither the watched
        // tick nor the unwatched dot applies.
        if presentation.artworkTreatment == .visible, !presentation.isUpcoming {
            switch watchStatusIndicator {
            case .watched:
                if presentation.isWatched {
                    let size = metrics.watchedBadgeSize
                    Image(systemName: "checkmark")
                        .font(.system(size: size * 0.53, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: size, height: size)
                        .background(Circle().fill(ThemePalette.brandBlue))
                        .overlay {
                            Circle()
                                .inset(by: -0.5)
                                .stroke(
                                    palette.isLight ? .black.opacity(0.15) : .white.opacity(0.4),
                                    lineWidth: max(1.5, size * 0.04)
                                )
                        }
                        .padding(12)
                        .shadow(color: .black.opacity(0.4), radius: size * 0.08, y: size * 0.026)
                }
            case .unwatched:
                if !presentation.isWatched, presentation.progress == nil {
                    TopTrailingCornerFlag()
                        .fill(ThemePalette.brandBlue)
                        .shadow(color: .black.opacity(0.28), radius: 8)
                        .frame(width: metrics.unwatchedFlagSize, height: metrics.unwatchedFlagSize)
                }
            }
        }
    }
}
#endif
