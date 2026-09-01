#if os(iOS)
import CoreModels
import CoreUI
import SwiftUI

struct PlozziOSPosterCard: View {
    let item: MediaItem?
    var style: PosterCardView.Style = .poster
    /// Identify the card by its show — artwork plus logo — instead of by the
    /// item's own thumbnail. Continue Watching opts in.
    var showsSeriesArtwork: Bool = false
    /// Spoiler protection for the card's artwork and text. Defaulted so the many
    /// callers that show already-watched or non-episode content stay unchanged;
    /// surfaces that can show unwatched episodes pass the profile's real settings.
    var spoilerSettings: SpoilerSettings = .default
    /// Draws the resume chip (play glyph + progress + time remaining) over the
    /// artwork, with an optional download badge — the same treatment tvOS uses.
    var showsResumeChip: Bool = false
    var downloadState: MediaDownloadBadgeState?
    /// Visible "…" menu. Touch cards need it: press-and-hold is undiscoverable.
    var showsActionsMenu: Bool = false
    /// Caller-owned context cue drawn on the artwork (e.g. "Continues" on a
    /// Related entry that continues the story you're looking at).
    var statusCue: LocalizedStringResource?
    var isPendingRemoval: Bool = false

    var body: some View {
        PosterCardView(
            item: item ?? placeholderItem,
            style: style,
            spoilerSettings: spoilerSettings,
            showsSeriesArtwork: showsSeriesArtwork,
            reservesSubtitleSpace: false,
            statusCue: statusCue,
            showsResumeChip: showsResumeChip,
            downloadState: downloadState,
            showsActionsMenu: showsActionsMenu,
            isPendingRemoval: isPendingRemoval,
            action: {}
        )
        .redacted(reason: item == nil ? .placeholder : [])
        .allowsHitTesting(item != nil)
    }

    private var placeholderItem: MediaItem {
        MediaItem(
            id: "placeholder",
            title: "Loading…",
            kind: .folder
        )
    }
}

enum PlozziOSMediaRailLayout {
    /// Visible edge-to-edge gap used by every horizontal media rail on iOS.
    /// This matches the season episode rail, whose spacing is the visual baseline.
    static let visibleSpacing: CGFloat = 14

    /// Borderless cards reserve side margins inside their layout slots for focus
    /// clearance. Subtract those margins so artwork still lands exactly
    /// `visibleSpacing` apart instead of silently adding both margins to the gap.
    static func stackSpacing(metrics: PlozzMetrics, cardStyle: CardStyle) -> CGFloat {
        switch cardStyle {
        case .framed:
            visibleSpacing
        case .borderless:
            max(0, visibleSpacing - metrics.borderlessCardSideMargin * 2)
        }
    }
}

extension UIDensity {
    var iOSPosterMinimumWidth: CGFloat {
        max(86, CGFloat(116 * scale))
    }

    func iOSPosterGridColumns(
        horizontalSizeClass: UserInterfaceSizeClass?
    ) -> [GridItem] {
        let minimumWidth = if horizontalSizeClass == .regular {
            max(108, CGFloat(144 * scale))
        } else {
            iOSPosterMinimumWidth
        }
        let spacing: CGFloat = horizontalSizeClass == .regular ? 16 : 12
        return [
            GridItem(
                .adaptive(
                    minimum: minimumWidth,
                    maximum: minimumWidth * 1.55
                ),
                spacing: spacing
            )
        ]
    }

    func iOSHomeLibraryWidth(
        horizontalSizeClass: UserInterfaceSizeClass?
    ) -> CGFloat {
        max(164, CGFloat((horizontalSizeClass == .regular ? 260 : 220) * scale))
    }
}
#endif
