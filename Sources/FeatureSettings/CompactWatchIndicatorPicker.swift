#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// The compact, in-Settings picker for the watch-status indicator: a row of
/// preview cards (`PreviewCard` + `WatchStatusIndicatorSwatch`) that share the
/// detail pane's width, mirroring `CompactThemePicker`. Tapping a card selects
/// that indicator; the active one carries the same accent wash/ring the theme and
/// music-player pickers use.
///
/// With only two choices there's plenty of horizontal room, so each card's
/// preview is given a taller swatch (via `PreviewCard`'s `swatchHeight`) than the
/// three/four-up theme and music pickers use — the mock poster row reads clearly.
struct CompactWatchIndicatorPicker: View {
    @Binding var selection: WatchStatusIndicator
    @Environment(\.themePalette) private var palette

    /// Roughly twice the standard compact swatch height (124pt); the two-up layout
    /// leaves room for a larger, more legible poster-row illustration.
    private let swatchHeight: CGFloat = 248

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach(WatchStatusIndicator.allCases) { indicator in
                PreviewCard(
                    title: indicator.displayName,
                    detail: indicator.detail,
                    isSelected: selection == indicator,
                    accent: palette.accent,
                    compact: true,
                    swatchHeight: swatchHeight,
                    action: { selection = indicator }
                ) {
                    WatchStatusIndicatorSwatch(
                        indicator: indicator,
                        cornerRadius: PlozzTheme.Metrics.Radius.content
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
