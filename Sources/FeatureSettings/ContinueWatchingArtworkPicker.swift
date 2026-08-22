#if canImport(SwiftUI)
import SwiftUI
import CoreUI

/// Card picker for the Continue Watching card style, mirroring the spoiler,
/// theme and music-player pickers: a preview of each option with the active card
/// ringed.
///
/// A picker rather than a switch on purpose. Both options put artwork on the
/// card — the choice is only *which* artwork — so any on/off label ("display
/// artwork", "display logo and artwork") implied that turning it off left the
/// card empty. Two named previews say what actually happens.
struct ContinueWatchingArtworkPicker: View {
    @Binding var style: ContinueWatchingArtworkStyle
    @Environment(\.themePalette) private var palette

    /// Between the Appearance pickers (150) and the navigation one (248). These
    /// previews carry more detail than a card-style swatch — a wordmark, a scene,
    /// a chip and the caption bars — and at the compact default of 124 the card
    /// inside was too small to read any of it.
    private let swatchHeight: CGFloat = 200

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach(ContinueWatchingArtworkStyle.allCases, id: \.self) { option in
                PreviewCard(
                    title: option.displayName,
                    detail: option.detail,
                    isSelected: style == option,
                    accent: palette.accent,
                    compact: true,
                    swatchHeight: swatchHeight,
                    action: { style = option }
                ) {
                    ContinueWatchingArtworkSwatch(
                        style: option,
                        cornerRadius: PlozzTheme.Metrics.Radius.content
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
