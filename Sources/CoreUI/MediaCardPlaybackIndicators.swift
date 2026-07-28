#if canImport(SwiftUI)
import CoreModels
import SwiftUI

public struct MediaCardPlaybackIndicators: View {
    /// Only the four `MediaItem` fields this view actually renders.
    ///
    /// SwiftUI compares a view's stored inputs field-by-field to decide whether
    /// to re-run its body, and `MediaItem` has 56 stored properties including
    /// several arrays. Storing the whole item made every card pay a 56-field
    /// deep comparison — plus a full struct copy — on every update pass. In a
    /// Time Profiler trace of ordinary browsing, `MediaItem.__derived_struct_equals`
    /// and `initializeWithCopy for MediaItem` were among the hottest symbols on
    /// the main thread. Narrowing the input is Apple's prescribed fix.
    private let playback: MediaPlaybackIndicatorState
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
    /// Published by the hosting card so this chrome can settle back at rest and
    /// come to full strength on focus (tvOS only — see ``PlozzMediaChrome``).
    @Environment(\.plozzChromeIsFocused) private var isFocused

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
        self.playback = MediaPlaybackIndicatorState(item)
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
            // One scrim for ALL bottom chrome, drawn beneath it. Shared with the
            // resume chip (``MediaArtworkChromeScrim``) so a card's bottom edge
            // darkens identically whichever treatment it carries.
            //
            // It used to live inside `progressBar`, which meant a downloaded but
            // unstarted card had its badge floating on bare artwork, and the ramp
            // was a full-length linear fade whose darkening was so spread out it
            // was hard to see at all. The shared scrim holds clear until ~62% and
            // then ramps, so the darkening is concentrated where the chrome is.
            .overlay {
                if hasBottomChrome {
                    MediaArtworkChromeScrim(top: false, bottom: true)
                }
            }
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
        MediaPlaybackIndicatorPresentation.showsProgress(for: playback)
    }

    /// Any chrome along the card's bottom edge that needs the artwork darkened
    /// behind it — the progress bar, the download badge, or both.
    private var hasBottomChrome: Bool {
        (progressBarEnabled && showsProgressBar) || downloadState != nil
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if PosterCardPresentation.showsWatchStatus(for: playback.kind) {
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
            for: playback,
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
            for: playback,
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
    ///
    /// The gap it leaves before the badge is the SAME value as the bar's own edge
    /// inset, so the whole strip is evenly spaced: inset · bar · inset · badge ·
    /// inset.
    private var progressTrailingInset: CGFloat {
        guard downloadState != nil else { return progressHorizontalInset }
        return progressHorizontalInset * 2 + downloadBadgeSize
    }

    @ViewBuilder
    private var progressBar: some View {
        if showsProgressBar, let percentage = playback.playedPercentage {
            let shadowRadius = progressHeight * 0.25
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Matches ``ResumeProgressCapsule`` — the same white bar the
                    // resume chip and the detail Play button draw — so progress
                    // reads identically wherever it appears. Deliberately not the
                    // brand blue: colour is reserved for specific moments, and a
                    // white bar sits better over arbitrary artwork.
                    Capsule(style: .continuous)
                        .fill(PlozzMediaChrome.track(isFocused: isFocused))
                    Capsule(style: .continuous)
                        .fill(PlozzMediaChrome.foreground(isFocused: isFocused))
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

/// The watch-state facts a card's indicators draw from — four values lifted out
/// of `MediaItem` so a card's comparison surface is bounded by what it shows.
/// See ``MediaCardPlaybackIndicators``'s stored property for the measurements.
public struct MediaPlaybackIndicatorState: Equatable, Sendable {
    public let kind: MediaItemKind
    public let isPlayed: Bool
    public let playedPercentage: Double?
    public let resumePosition: Double?

    public init(_ item: MediaItem) {
        kind = item.kind
        isPlayed = item.isPlayed
        playedPercentage = item.playedPercentage
        resumePosition = item.resumePosition
    }
}

enum MediaPlaybackIndicatorPresentation {
    static func showsProgress(for item: MediaPlaybackIndicatorState) -> Bool {
        guard PosterCardPresentation.showsPlaybackIndicators(for: item.kind),
              let percentage = item.playedPercentage
        else { return false }
        return percentage > 0.01 && percentage < 0.99
    }

    static func hasStartedPlayback(_ item: MediaPlaybackIndicatorState) -> Bool {
        if let percentage = item.playedPercentage, percentage > 0 { return true }
        if let resume = item.resumePosition, resume > 0 { return true }
        return false
    }

    static func showsWatchedBadge(
        for item: MediaPlaybackIndicatorState,
        hidesStatus: Bool
    ) -> Bool {
        item.isPlayed && !showsProgress(for: item) && !hidesStatus
    }

    static func showsUnwatchedFlag(
        for item: MediaPlaybackIndicatorState,
        hidesStatus: Bool
    ) -> Bool {
        !item.isPlayed && !hasStartedPlayback(item) && !hidesStatus
    }
}
#endif
