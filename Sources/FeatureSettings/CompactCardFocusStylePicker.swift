#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// The compact, in-Settings picker for what focus does to a card: a two-up row of
/// preview cards (`PreviewCard` + `CardFocusStyleSwatch`) that share the detail
/// pane's width, mirroring `CompactCardStylePicker` and
/// `CompactWatchIndicatorPicker` so the three controls in the Cards pane read as
/// one family.
struct CompactCardFocusStylePicker: View {
    @Binding var selection: CardFocusStyle
    /// Preview swatch height. Pass the same value as its siblings when the picker
    /// shares a pane with them.
    var swatchHeight: CGFloat = 248
    @Environment(\.themePalette) private var palette

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach(CardFocusStyle.allCases) { style in
                PreviewCard(
                    title: style.displayName,
                    detail: style.detail,
                    isSelected: selection == style,
                    accent: palette.accent,
                    compact: true,
                    swatchHeight: swatchHeight,
                    action: { selection = style }
                ) {
                    CardFocusStyleSwatch(
                        style: style,
                        cornerRadius: PlozzTheme.Metrics.Radius.content
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
