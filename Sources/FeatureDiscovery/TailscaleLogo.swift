#if canImport(SwiftUI)
import SwiftUI

/// The Tailscale dot-grid logo, drawn with vector shapes (no bundled asset) so
/// it scales crisply and adapts to the surrounding tint.
///
/// The mark is a 3×3 grid of dots: the middle row and the bottom-centre dot are
/// solid, the remaining five are outline rings — matching Tailscale's wordmark
/// glyph.
struct TailscaleLogo: View {
    var color: Color = .primary

    /// Grid positions (row, column) drawn as solid dots; the rest are rings.
    private static let solids: Set<[Int]> = [[1, 0], [1, 1], [1, 2], [2, 1]]

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let cell = side / 3
            let dot = cell * 0.66
            let line = max(1, dot * 0.16)

            ZStack {
                ForEach(0..<3, id: \.self) { row in
                    ForEach(0..<3, id: \.self) { col in
                        dotShape(row: row, col: col, lineWidth: line)
                            .frame(width: dot, height: dot)
                            .position(
                                x: cell * (CGFloat(col) + 0.5),
                                y: cell * (CGFloat(row) + 0.5)
                            )
                    }
                }
            }
            .frame(width: side, height: side)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func dotShape(row: Int, col: Int, lineWidth: CGFloat) -> some View {
        if Self.solids.contains([row, col]) {
            Circle().fill(color)
        } else {
            Circle().strokeBorder(color, lineWidth: lineWidth)
        }
    }
}

#endif
