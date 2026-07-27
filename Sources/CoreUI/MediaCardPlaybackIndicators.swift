#if canImport(SwiftUI)
import CoreModels
import SwiftUI

public struct MediaCardPlaybackIndicators: View {
    private let item: MediaItem
    private let hidesStatus: Bool
    private let progressBarEnabled: Bool
    private let badgeInset: CGFloat
    private let progressHeight: CGFloat
    private let progressHorizontalInset: CGFloat
    private let progressBottomInset: CGFloat
    /// Offline state for this item, drawn bottom-trailing. Lives here (rather than
    /// only inside the resume chip) because "is this downloaded?" is wanted on
    /// EVERY card, including plain browsing posters that carry no chip.
    private let downloadState: MediaDownloadBadgeState?

    @Environment(\.plozzMetrics) private var metrics
    @Environment(\.plozzWatchStatusIndicator) private var watchStatusIndicator
    @Environment(\.themePalette) private var palette

    public init(
        item: MediaItem,
        hidesStatus: Bool = false,
        showsProgressBar: Bool = true,
        badgeInset: CGFloat,
        progressHeight: CGFloat = 0,
        progressHorizontalInset: CGFloat = 0,
        progressBottomInset: CGFloat = 0,
        downloadState: MediaDownloadBadgeState? = nil
    ) {
        self.item = item
        self.hidesStatus = hidesStatus
        self.progressBarEnabled = showsProgressBar
        self.badgeInset = badgeInset
        self.progressHeight = progressHeight
        self.progressHorizontalInset = progressHorizontalInset
        self.progressBottomInset = progressBottomInset
        self.downloadState = downloadState
    }

    public var body: some View {
        Color.clear
            .overlay(alignment: .topTrailing) {
                statusIndicator
            }
            .overlay(alignment: .bottom) {
                if progressBarEnabled {
                    progressBar
                }
            }
            .overlay(alignment: .bottomTrailing) {
                downloadBadge
            }
            .allowsHitTesting(false)
    }

    private var showsProgressBar: Bool {
        MediaPlaybackIndicatorPresentation.showsProgress(for: item)
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if PosterCardPresentation.showsWatchStatus(for: item.kind) {
            switch watchStatusIndicator {
            case .watched:
                watchedBadge
            case .unwatched:
                unwatchedCorner
            }
        }
    }

    @ViewBuilder
    private var watchedBadge: some View {
        if MediaPlaybackIndicatorPresentation.showsWatchedBadge(
            for: item,
            hidesStatus: hidesStatus
        ) {
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
                            palette.isLight
                                ? .black.opacity(0.15)
                                : .white.opacity(0.4),
                            lineWidth: max(1.5, size * 0.04)
                        )
                }
                .padding(badgeInset)
                .shadow(
                    color: .black.opacity(0.4),
                    radius: size * 0.08,
                    y: size * 0.026
                )
        }
    }

    @ViewBuilder
    private var unwatchedCorner: some View {
        if MediaPlaybackIndicatorPresentation.showsUnwatchedFlag(
            for: item,
            hidesStatus: hidesStatus
        ) {
            TopTrailingCornerFlag()
                .fill(ThemePalette.brandBlue)
                .shadow(color: .black.opacity(0.28), radius: 8)
                .overlay(alignment: .topTrailing) {
                    TopTrailingCornerFlagEdge()
                        .stroke(Color.black.opacity(0.3), lineWidth: 1)
                }
                .frame(
                    width: metrics.unwatchedFlagSize,
                    height: metrics.unwatchedFlagSize
                )
        }
    }

    /// Offline indicator, pinned to ONE fixed spot in the bottom-trailing corner.
    /// It never moves for the progress bar — a badge that shifts depending on
    /// whether an item happens to be part-watched reads as a glitch across a wall
    /// of cards. The bar yields to it instead (see ``progressTrailingInset``).
    @ViewBuilder
    private var downloadBadge: some View {
        if let downloadState {
            // Same size the resume chip drew it at, so a downloaded card's badge
            // doesn't change scale depending on which chrome path it takes. The
            // larger `watchedBadgeSize` would eat half an 86pt poster.
            MediaDownloadBadge(state: downloadState, size: downloadBadgeSize)
                .padding(.trailing, progressHorizontalInset)
                .padding(.bottom, downloadBadgeBottomInset)
                .shadow(color: .black.opacity(0.45), radius: 4, y: 1)
        }
    }

    private var downloadBadgeSize: CGFloat { metrics.resumeChipAccessorySize }

    /// Centres the badge on the bar's line rather than sharing its baseline — the
    /// badge is taller than the bar, so a shared baseline leaves its mass sitting
    /// above the line. Derived only from constants, so the badge lands in the
    /// identical spot on every card whether or not a bar is drawn.
    private var downloadBadgeBottomInset: CGFloat {
        max(0, progressBottomInset - (downloadBadgeSize - progressHeight) / 2)
    }

    /// The bar runs from the leading edge to just before the download badge, so
    /// the two sit on one line and neither is obscured. With no badge it reaches
    /// the card's normal inset.
    private var progressTrailingInset: CGFloat {
        guard downloadState != nil else { return progressHorizontalInset }
        return progressHorizontalInset + downloadBadgeSize + 8
    }

    @ViewBuilder
    private var progressBar: some View {
        if showsProgressBar, let percentage = item.playedPercentage {
            let scrimReach = progressHeight * 7.5
            let shadowRadius = progressHeight * 0.25
            ZStack(alignment: .bottom) {
                LinearGradient(
                    colors: [.clear, .black.opacity(0.6)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: progressHeight + scrimReach)
                .frame(maxWidth: .infinity)

                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        // Matches ``ResumeProgressCapsule`` — the same white bar the
                        // resume chip and the detail Play button draw — so progress
                        // reads identically wherever it appears. Deliberately not the
                        // brand blue: colour is reserved for specific moments, and a
                        // white bar sits better over arbitrary artwork.
                        Capsule(style: .continuous)
                            .fill(.white.opacity(0.32))
                        Capsule(style: .continuous)
                            .fill(.white)
                            .frame(
                                width: max(
                                    progressHeight,
                                    geometry.size.width * percentage
                                )
                            )
                            .shadow(
                                color: .black.opacity(0.35),
                                radius: shadowRadius
                            )
                    }
                }
                .frame(height: progressHeight)
                .padding(.leading, progressHorizontalInset)
                .padding(.trailing, progressTrailingInset)
                .padding(.bottom, progressBottomInset)
            }
        }
    }
}

enum MediaPlaybackIndicatorPresentation {
    static func showsProgress(for item: MediaItem) -> Bool {
        guard PosterCardPresentation.showsPlaybackIndicators(for: item.kind),
              let percentage = item.playedPercentage
        else { return false }
        return percentage > 0.01 && percentage < 0.99
    }

    static func hasStartedPlayback(_ item: MediaItem) -> Bool {
        if let percentage = item.playedPercentage, percentage > 0 { return true }
        if let resume = item.resumePosition, resume > 0 { return true }
        return false
    }

    static func showsWatchedBadge(
        for item: MediaItem,
        hidesStatus: Bool
    ) -> Bool {
        item.isPlayed && !showsProgress(for: item) && !hidesStatus
    }

    static func showsUnwatchedFlag(
        for item: MediaItem,
        hidesStatus: Bool
    ) -> Bool {
        !item.isPlayed && !hasStartedPlayback(item) && !hidesStatus
    }
}
#endif
