#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// The detail-pane content for the "Music Player" settings row: the style
/// preview cards with the "Show track details" toggle beneath.
///
/// Wrapped in a `focusScope` with the picker marked `prefersDefaultFocus`, so
/// pressing **right** from the master list lands on the style cards first —
/// otherwise the focus engine picks the geometrically-nearest control (the
/// toggle, which sits closer to the master row) instead of the top card.
struct MusicPlayerStyleDetail: View {
    @Binding var appearance: MusicPlayerAppearance
    @Binding var showTrackDetails: Bool
    @Namespace private var scope

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            CompactMusicStylePicker(selection: $appearance)
                .prefersDefaultFocus(in: scope)

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Show track details", isOn: $showTrackDetails)
                Text("Album name, audio quality & lyrics source on the now-playing screen.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .focusScope(scope)
    }
}

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
