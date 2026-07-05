#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// The compact, in-Settings music-player style picker: a row of smaller preview
/// cards (`PreviewCard` + `MusicStyleSwatch`) that share the detail pane's width,
/// mirroring `CompactThemePicker`. Tapping a card selects that appearance; the
/// active one carries the same accent wash/ring.
struct CompactMusicStylePicker: View {
    @Binding var selection: MusicPlayerAppearance
    @Environment(\.themePalette) private var palette

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach(MusicPlayerAppearance.pickerOrder) { appearance in
                PreviewCard(
                    title: appearance.displayName,
                    isSelected: selection == appearance,
                    accent: palette.accent,
                    compact: true,
                    action: { selection = appearance }
                ) {
                    MusicStyleSwatch(appearance: appearance, cornerRadius: 10)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Group the cards so moving DOWN from any card (incl. the edge ones)
        // reliably exits to the "Show track details" toggle beneath.
        .focusSection()
    }
}
#endif
