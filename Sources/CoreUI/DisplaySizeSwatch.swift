#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// Fixed, theme-independent colours for the display-size preview — a *picture*
/// of the feature that looks the same in every theme (like `CardStylePreviewColors`
/// / `WatchIndicatorPreviewColors`).
private enum DisplaySizePreviewColors {
    static let screen = Color(red: 0.10, green: 0.10, blue: 0.12)
    static let border = Color.white.opacity(0.12)
    /// A small palette of muted poster gradients, cycled across the grid so
    /// neighbouring mock posters read as distinct without pulling focus.
    static let tileArt: [[Color]] = [
        [Color(red: 0.24, green: 0.52, blue: 0.62), Color(red: 0.14, green: 0.28, blue: 0.44)],
        [Color(red: 0.55, green: 0.34, blue: 0.52), Color(red: 0.30, green: 0.18, blue: 0.36)],
        [Color(red: 0.60, green: 0.44, blue: 0.28), Color(red: 0.36, green: 0.24, blue: 0.16)],
        [Color(red: 0.30, green: 0.52, blue: 0.40), Color(red: 0.16, green: 0.32, blue: 0.26)]
    ]
}

/// A **mini TV screen** filled with a poster grid at one `UIDensity` — the honest
/// picture of what that density does. The outer screen rectangle is the *same
/// fixed 16:9 size for every option* (a TV's width doesn't change), and inside it
/// we lay out the density's real `posterGridColumns`: so denser options pack many
/// small posters across the same screen and roomier ones show a few big ones.
/// Extra rows are drawn and clipped so each swatch looks like a real browse wall
/// (and larger sizes reveal only ~one row, exactly as on-device).
///
/// This replaces the earlier "same tiles, just bigger" strip, which wrongly
/// implied the screen grew with the cards.
public struct DisplaySizeSwatch: View {
    private let density: UIDensity
    private let screen: CGSize

    /// - Parameter screenHeight: height of the mini TV; width is derived at 16:9
    ///   so the preview matches a real TV's aspect ratio.
    public init(density: UIDensity, screenHeight: CGFloat = 92) {
        self.density = density
        self.screen = CGSize(width: (screenHeight * 16.0 / 9.0).rounded(), height: screenHeight)
    }

    private let bezel: CGFloat = 5
    private let gap: CGFloat = 2.5

    private var columns: Int { density.posterGridColumns }
    private var gridWidth: CGFloat { screen.width - bezel * 2 }
    private var gridHeight: CGFloat { screen.height - bezel * 2 }
    private var cardWidth: CGFloat {
        (gridWidth - CGFloat(columns - 1) * gap) / CGFloat(columns)
    }
    private var cardHeight: CGFloat { cardWidth * 1.5 } // 2:3 poster
    /// Enough rows to fill the screen plus one that clips at the bottom edge, so
    /// the wall reads as scrollable content rather than a lone row.
    private var rowCount: Int {
        max(1, Int(ceil((gridHeight + gap) / (cardHeight + gap))) + 1)
    }
    private var corner: CGFloat { max(1.5, cardWidth * 0.14) }

    public var body: some View {
        VStack(spacing: gap) {
            ForEach(0..<rowCount, id: \.self) { r in
                HStack(spacing: gap) {
                    ForEach(0..<columns, id: \.self) { c in
                        RoundedRectangle(cornerRadius: corner, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: DisplaySizePreviewColors.tileArt[(r * columns + c) % DisplaySizePreviewColors.tileArt.count],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: cardWidth, height: cardHeight)
                    }
                }
            }
        }
        .frame(width: gridWidth, height: gridHeight, alignment: .topLeading)
        .clipped()
        .padding(bezel)
        .frame(width: screen.width, height: screen.height)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(DisplaySizePreviewColors.screen)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(DisplaySizePreviewColors.border, lineWidth: 1)
        )
    }
}
#endif
