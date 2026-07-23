#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import MetadataKit

/// The fixed standard-size, borderless episode column used only on series detail.
public struct EpisodeColumnCard: View {
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
        VStack(alignment: .leading, spacing: 0) {
            artwork
                .frame(width: Self.artworkSize.width, height: Self.artworkSize.height)
                .overlay { bottomLeadingScrim }
                .overlay(alignment: .topTrailing) { statusIndicator }
                .overlay(alignment: .bottomLeading) { progressBar }
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
                Text(presentation.titleLine)
                    .font(.system(size: metrics.cardTitleFontSize, weight: .semibold))
                    .foregroundStyle(.primary)
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
        .zIndex(isFocused ? 2 : 0)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isFocused)
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

    private var placeholderArtwork: some View {
        FallbackAsyncImage(
            urls: [item.fallbackArtworkURL].compactMap { $0 },
            variant: .landscapeCard
        ) {
            neutralPlaceholder
        }
    }

    private var neutralPlaceholder: some View {
        ZStack {
            Color.secondary.opacity(0.08)
            VStack(spacing: 10) {
                Image(systemName: "play.rectangle")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text(item.parentTitle ?? "Episode")
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }
        }
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
        if presentation.artworkTreatment == .visible {
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

    @ViewBuilder
    private var progressBar: some View {
        if presentation.artworkTreatment != .blurred {
            EpisodeWatchStatePill(
                item: item,
                showsRuntimeWhenIdle: true,
                showsWatched: false,
                showsBackground: false,
                barWidth: 80,
                barHeight: 6
            )
            .font(.system(size: 24, weight: .semibold))
            .padding(18)
        }
    }

    /// A subtle corner-anchored legibility scrim behind the resume/runtime pill:
    /// dark at the bottom-leading corner fading to clear, so the white
    /// play/progress/time chip reads cleanly without a solid capsule (matches the
    /// iOS/iPadOS episode card). Drawn whenever the pill has runtime/progress to
    /// show (``metadataText`` mirrors the pill's own show/hide condition).
    @ViewBuilder
    private var bottomLeadingScrim: some View {
        if presentation.artworkTreatment != .blurred, presentation.metadataText != nil {
            GeometryReader { proxy in
                RadialGradient(
                    colors: [.black.opacity(0.55), .clear],
                    center: .bottomLeading,
                    startRadius: 0,
                    endRadius: max(proxy.size.width, proxy.size.height) * 0.8
                )
            }
            .allowsHitTesting(false)
        }
    }
}
#endif
