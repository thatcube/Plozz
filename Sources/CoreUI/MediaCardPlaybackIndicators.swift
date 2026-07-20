#if canImport(SwiftUI)
import CoreModels
import SwiftUI

public struct MediaCardPlaybackIndicators: View {
    private let item: MediaItem
    private let hidesStatus: Bool
    private let badgeInset: CGFloat
    private let progressHeight: CGFloat
    private let progressHorizontalInset: CGFloat
    private let progressBottomInset: CGFloat

    @Environment(\.plozzMetrics) private var metrics
    @Environment(\.plozzWatchStatusIndicator) private var watchStatusIndicator
    @Environment(\.themePalette) private var palette

    public init(
        item: MediaItem,
        hidesStatus: Bool = false,
        badgeInset: CGFloat,
        progressHeight: CGFloat,
        progressHorizontalInset: CGFloat,
        progressBottomInset: CGFloat
    ) {
        self.item = item
        self.hidesStatus = hidesStatus
        self.badgeInset = badgeInset
        self.progressHeight = progressHeight
        self.progressHorizontalInset = progressHorizontalInset
        self.progressBottomInset = progressBottomInset
    }

    public var body: some View {
        Color.clear
            .overlay(alignment: .topTrailing) {
                statusIndicator
            }
            .overlay(alignment: .bottom) {
                progressBar
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
                        Capsule(style: .continuous)
                            .fill(.white.opacity(0.22))
                        Capsule(style: .continuous)
                            .fill(ThemePalette.brandBlue)
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
                .padding(.horizontal, progressHorizontalInset)
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
