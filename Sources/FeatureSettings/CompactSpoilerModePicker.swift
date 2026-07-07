#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// Card picker for the spoiler hide-mode, mirroring the theme and music-player
/// pickers: a live preview of each mode (a blurred still vs. generic placeholder
/// art) with the active card ringed. Replaces the old inline pill picker so the
/// choice is shown, not just labelled.
struct SpoilerModePicker: View {
    @Binding var mode: SpoilerSettings.Mode
    @Environment(\.themePalette) private var palette

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach(SpoilerSettings.Mode.allCases, id: \.self) { option in
                PreviewCard(
                    title: option.displayName,
                    isSelected: mode == option,
                    accent: palette.accent,
                    compact: true,
                    action: { mode = option }
                ) {
                    SpoilerModeSwatch(mode: option, cornerRadius: PlozzTheme.Metrics.Radius.content)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
