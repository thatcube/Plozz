#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// The compact, in-Settings picker for Display Size: a grid of preview cards
/// (`PreviewCard` + `DisplaySizeSwatch`) mirroring the Card Style / Watched
/// Indicator / Navigation pickers, so every Appearance picker reads the same way.
/// Each card's swatch is a mock screen filled with neutral placeholder posters at
/// that density's card size, so the six cards read as a size ramp (many small
/// cards → few big ones). Tapping a card selects that density; the active one
/// carries the same accent wash/ring the sibling pickers use.
///
/// Six options don't fit comfortably in one row, so they wrap to a 3-up grid
/// (Micro/Tiny/Small over Default/Large/Huge) — the natural reading order keeps
/// the ramp legible.
struct CompactDisplaySizePicker: View {
    @Binding var selection: UIDensity
    @Environment(\.themePalette) private var palette

    /// A shorter swatch than the two-up pickers use: with three cards per row the
    /// cards are narrower, so this keeps each mock screen a landscape (TV) shape
    /// rather than a tall box.
    private let swatchHeight: CGFloat = 150
    private let columnsPerRow = 3

    private var rows: [[UIDensity]] {
        stride(from: 0, to: UIDensity.allCases.count, by: columnsPerRow).map { start in
            Array(UIDensity.allCases[start..<min(start + columnsPerRow, UIDensity.allCases.count)])
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, rowDensities in
                HStack(alignment: .top, spacing: 16) {
                    ForEach(rowDensities) { density in
                        PreviewCard(
                            title: density.displayName,
                            detail: density.detail,
                            isSelected: selection == density,
                            accent: palette.accent,
                            compact: true,
                            swatchHeight: swatchHeight,
                            action: { selection = density }
                        ) {
                            DisplaySizeSwatch(
                                density: density,
                                cornerRadius: PlozzTheme.Metrics.Radius.content
                            )
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
#endif
