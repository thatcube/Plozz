#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// Fixed, theme-independent colours for the watch-indicator preview swatch. Like
/// `ThemePreviewColors`, these are a *picture* of the feature and never adapt to
/// the currently applied theme, so the illustration looks the same in every
/// theme.
private enum WatchIndicatorPreviewColors {
    static let bgTop = Color(red: 0.17, green: 0.17, blue: 0.19)
    static let bgBottom = Color(red: 0.10, green: 0.10, blue: 0.12)
    static let titleSecondary = Color.white.opacity(0.28)
    static let tileBorder = Color.white.opacity(0.12)
    static let progressTrack = Color.white.opacity(0.28)

    /// Three distinct fixed poster gradients so the mock row reads as three
    /// different titles (finished · in-progress · new), left → right.
    static let tileArt: [[Color]] = [
        [Color(red: 0.24, green: 0.52, blue: 0.62), Color(red: 0.14, green: 0.28, blue: 0.44)],
        [Color(red: 0.55, green: 0.32, blue: 0.60), Color(red: 0.28, green: 0.18, blue: 0.44)],
        [Color(red: 0.62, green: 0.44, blue: 0.30), Color(red: 0.40, green: 0.22, blue: 0.20)]
    ]
}

/// The three mock poster states the row illustrates, left → right.
private enum PreviewTileState {
    case finished
    case inProgress
    case new
}

/// A tiny mock "poster row" painted with fixed colours: a faux title bar over
/// three poster tiles representing a finished title, an in-progress title (always
/// shows a progress bar) and a brand-new title. Which tiles wear a corner mark is
/// driven by `indicator`, so the two option cards differ only in *where* the mark
/// lands — exactly the choice the setting makes. Fills whatever frame the caller
/// gives it and stays proportionate at the compact and full sizes.
private struct WatchIndicatorMini: View {
    let indicator: WatchStatusIndicator

    private let states: [PreviewTileState] = [.finished, .inProgress, .new]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let pad = max(10, h * 0.11)
            let titleGap = h * 0.08
            let barH = max(3, h * 0.035)
            let gap = max(6, w * 0.03)
            // The tile is a 2:3 poster sized to fit BOTH the row's available height
            // and its available width (three tiles + two gaps). Taking the smaller
            // of the two keeps the mock row inside the card at any aspect — a short
            // wide card is height-bound, a tall narrow one is width-bound — so the
            // taller two-up watch picker never overflows its card.
            let rowH = max(0, h - pad * 2 - barH - titleGap)
            let contentW = max(0, w - pad * 2)
            let widthBoundTileW = max(0, (contentW - gap * 2) / 3)
            let tileW = min(rowH * (2.0 / 3.0), widthBoundTileW)
            let tileH = tileW * (3.0 / 2.0)
            // Exact width of the three-tile poster row; the title bar block is
            // constrained to this and the whole thing is centred, so the bars'
            // leading edge lines up with the posters' leading edge.
            let rowWidth = tileW * 3 + gap * 2

            VStack(alignment: .leading, spacing: titleGap) {
                // Faux title bar — both bars a muted grey so they read as quiet
                // placeholder chrome and don't compete with the posters.
                HStack(spacing: rowWidth * 0.03) {
                    Capsule().fill(WatchIndicatorPreviewColors.titleSecondary)
                        .frame(width: rowWidth * 0.30, height: barH)
                    Capsule().fill(WatchIndicatorPreviewColors.titleSecondary)
                        .frame(width: rowWidth * 0.46, height: barH)
                }
                // Three poster tiles.
                HStack(spacing: gap) {
                    ForEach(Array(states.enumerated()), id: \.offset) { index, state in
                        posterTile(state: state, artIndex: index, width: tileW, height: tileH)
                    }
                }
            }
            .frame(width: rowWidth)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .padding(pad)
            .frame(width: w, height: h, alignment: .topLeading)
            .background(
                LinearGradient(
                    colors: [WatchIndicatorPreviewColors.bgTop, WatchIndicatorPreviewColors.bgBottom],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
    }

    @ViewBuilder
    private func posterTile(state: PreviewTileState, artIndex: Int, width: CGFloat, height: CGFloat) -> some View {
        let corner = min(width, height) * 0.12
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(
                LinearGradient(
                    colors: WatchIndicatorPreviewColors.tileArt[artIndex],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            // Dull the mock artwork — same hues, less vibrant — so the posters read
            // as quiet stand-ins and the corner marks stay the focus. Applied only
            // to the fill (before the overlays) so the brand-blue flag/check keep
            // their full saturation.
            .saturation(0.45)
            .overlay(alignment: .topTrailing) { cornerMark(for: state, tileWidth: width) }
            .overlay(alignment: .bottom) { progressBar(for: state, tileWidth: width, tileHeight: height) }
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(WatchIndicatorPreviewColors.tileBorder, lineWidth: 1)
            )
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }

    /// The corner mark for a tile, matching the real card: a "watched" check on
    /// the finished tile (only in `.watched` mode) or an "unwatched" flag on the
    /// new tile (only in `.unwatched` mode). In-progress tiles never get a mark.
    @ViewBuilder
    private func cornerMark(for state: PreviewTileState, tileWidth: CGFloat) -> some View {
        switch (indicator, state) {
        case (.watched, .finished):
            let d = tileWidth * 0.47
            Image(systemName: "checkmark")
                .font(.system(size: d * 0.52, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: d, height: d)
                .background(Circle().fill(ThemePalette.brandBlue))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.4), lineWidth: 1))
                .padding(tileWidth * 0.09)
        case (.unwatched, .new):
            let s = tileWidth * 0.62
            TopTrailingCornerFlag()
                .fill(ThemePalette.brandBlue)
                .shadow(color: .black.opacity(0.28), radius: s * 0.16)
                .overlay(alignment: .topTrailing) {
                    TopTrailingCornerFlagEdge()
                        .stroke(Color.black.opacity(0.3), lineWidth: 1)
                }
                .frame(width: s, height: s)
        default:
            EmptyView()
        }
    }

    /// The in-progress tile always shows a partial progress bar — the same in both
    /// modes — so the illustration also conveys that in-progress items are never
    /// marked watched.
    @ViewBuilder
    private func progressBar(for state: PreviewTileState, tileWidth: CGFloat, tileHeight: CGFloat) -> some View {
        if case .inProgress = state {
            let barH = max(3, tileHeight * 0.05)
            let inset = tileWidth * 0.12
            ZStack(alignment: .leading) {
                Capsule().fill(WatchIndicatorPreviewColors.progressTrack)
                Capsule().fill(ThemePalette.brandBlue)
                    .frame(width: (tileWidth - inset * 2) * 0.55)
            }
            .frame(height: barH)
            .padding(.horizontal, inset)
            .padding(.bottom, inset)
        }
    }
}

/// The per-option preview graphic for the watch-status indicator picker: a mock
/// poster row whose corner mark lands on the finished title (`.watched`) or the
/// new title (`.unwatched`). Fills the caller's frame, so it scales for both the
/// full and compact card sizes, mirroring `ThemeSwatch` / `MusicStyleSwatch`.
public struct WatchStatusIndicatorSwatch: View {
    private let indicator: WatchStatusIndicator
    private let cornerRadius: CGFloat

    public init(indicator: WatchStatusIndicator, cornerRadius: CGFloat = 16) {
        self.indicator = indicator
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        WatchIndicatorMini(indicator: indicator)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color(white: 0.5).opacity(0.35), lineWidth: 1)
            )
    }
}
#endif
