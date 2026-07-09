#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// The detail-pane content for the "Music Player" settings row: the style
/// preview cards with the "Show track details" toggle beneath.
///
/// Pressing **right** from the master list must land on the style cards, not the
/// toggle. The focus engine picks the geometrically-nearest control, and since
/// "Music Player" sits low in the master list the toggle is closer than the top
/// cards — and neither `prefersDefaultFocus` nor `.defaultFocus` overrides a
/// directional move, while redirecting off the (visible) toggle looks janky.
///
/// Instead we simply keep the toggle OUT of the focus order until a style card
/// has been focused: `FocusGatedSwitch(canFocus:)` uses the custom settings
/// button style, so disabling it removes it from focus without dimming. On entry
/// the cards are therefore the only focus target; once one is focused
/// (`cardFocused`) the toggle joins the focus order so **down** reaches it. The
/// gate resets when focus leaves the pane, re-applying on the next entry.
struct MusicPlayerStyleDetail: View {
    @Binding var appearance: MusicPlayerAppearance
    @Binding var showTrackDetails: Bool
    @Environment(\.themePalette) private var palette
    @FocusState private var focused: FocusTarget?
    /// Whether a style card has been focused this entry — gates the toggle into
    /// the focus order so it can't steal the initial right-press.
    @State private var cardFocused = false

    private enum FocusTarget: Hashable {
        case style(MusicPlayerAppearance)
        case toggle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(MusicPlayerAppearance.pickerOrder) { style in
                    PreviewCard(
                        title: style.displayName,
                        isSelected: appearance == style,
                        accent: palette.accent,
                        compact: true,
                        action: { appearance = style }
                    ) {
                        MusicStyleSwatch(appearance: style, cornerRadius: PlozzTheme.Metrics.Radius.content)
                    }
                    .focused($focused, equals: .style(style))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            FocusGatedSwitch("Show album, quality & lyrics", isOn: $showTrackDetails, canFocus: cardFocused)
                .focused($focused, equals: .toggle)
        }
        .focusSection()
        .onChange(of: focused) { _, new in
            switch new {
            case .style:
                // A card is focused — let the toggle into the focus order so
                // pressing down can reach it.
                cardFocused = true
            case .none:
                // Focus left the pane (back to the master list) — re-gate so the
                // next entry can't land on the toggle.
                cardFocused = false
            case .toggle:
                break
            }
        }
    }
}
#endif
