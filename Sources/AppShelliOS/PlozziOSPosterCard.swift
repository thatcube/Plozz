#if os(iOS)
import CoreModels
import CoreUI
import SwiftUI

struct PlozziOSPosterCard: View {
    let item: MediaItem?
    var style: PosterCardView.Style = .poster
    /// Draws the resume chip (play glyph + progress + time remaining) over the
    /// artwork, with an optional download badge — the same treatment tvOS uses.
    var showsResumeChip: Bool = false
    var downloadState: MediaDownloadBadgeState?

    var body: some View {
        PosterCardView(
            item: item ?? placeholderItem,
            style: style,
            reservesSubtitleSpace: false,
            showsResumeChip: showsResumeChip,
            downloadState: downloadState,
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
