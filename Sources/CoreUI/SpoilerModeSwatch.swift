#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// A small, self-contained preview of how spoiler-hidden episodes look in each
/// ``SpoilerSettings/Mode`` — rendered as a mini **rail of three episodes**, the
/// way you'd see them while browsing a season. Mirrors the real `PosterCardView`
/// treatment: **Blur** shows the real stills, blurred; **Placeholder** swaps in
/// generic art with the episode number so not even a blurred frame leaks. Both
/// keep the title hidden until watched, shown as a redacted bar under each tile.
///
/// Fabricated graphic (no real media, network or theme needed), like
/// ``MusicStyleSwatch`` — it's a *picture* of each mode. Fills the caller's frame.
public struct SpoilerModeSwatch: View {
    private let mode: SpoilerSettings.Mode
    private let cornerRadius: CGFloat

    public init(mode: SpoilerSettings.Mode, cornerRadius: CGFloat = 12) {
        self.mode = mode
        self.cornerRadius = cornerRadius
    }

    /// Three distinct "scenes" so the blurred rail reads as three different
    /// episodes rather than one repeated tile.
    private static let scenes: [[Color]] = [
        [Color(red: 0.18, green: 0.50, blue: 0.72), Color(red: 0.60, green: 0.26, blue: 0.54)],
        [Color(red: 0.86, green: 0.44, blue: 0.22), Color(red: 0.52, green: 0.18, blue: 0.42)],
        [Color(red: 0.20, green: 0.56, blue: 0.44), Color(red: 0.18, green: 0.30, blue: 0.60)]
    ]

    public var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let spacing = w * 0.04
            let tileW = (w - spacing * 2) / 3
            HStack(alignment: .top, spacing: spacing) {
                ForEach(0..<3, id: \.self) { index in
                    episodeTile(index: index, width: tileW, height: h)
                }
            }
            .frame(width: w, height: h, alignment: .top)
        }
    }

    /// One mini episode card in the rail: the mode's thumbnail treatment plus a
    /// redacted title bar (hidden in both modes).
    private func episodeTile(index: Int, width: CGFloat, height: CGFloat) -> some View {
        let tileCorner = min(cornerRadius, width * 0.16)
        return VStack(alignment: .leading, spacing: height * 0.08) {
            ZStack {
                switch mode {
                case .blur:
                    fakeStill(index: index).blur(radius: width * 0.10)
                case .placeholder:
                    placeholderArt(index: index, width: width)
                }
            }
            .frame(width: width, height: height * 0.60)
            .clipShape(RoundedRectangle(cornerRadius: tileCorner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: tileCorner, style: .continuous)
                    .strokeBorder(Color(white: 0.5).opacity(0.3), lineWidth: 1)
            )

            Capsule()
                .fill(Color.primary.opacity(0.16))
                .frame(width: width * 0.82, height: max(4, height * 0.07))
        }
        .frame(width: width)
    }

    /// A fabricated "episode still" — a colourful scene so its blurred version
    /// clearly reads as a real (hidden) frame rather than a flat wash.
    private func fakeStill(index: Int) -> some View {
        let colors = Self.scenes[index % Self.scenes.count]
        return GeometryReader { geo in
            let w = geo.size.width
            ZStack {
                LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(
                    colors: [Color(red: 0.99, green: 0.82, blue: 0.40).opacity(0.85), .clear],
                    center: .init(x: 0.66, y: 0.34),
                    startRadius: 0,
                    endRadius: w * 0.7
                )
            }
        }
    }

    /// The "no real frame" look: a muted fill with a play glyph + the episode
    /// number, matching `PosterCardView`'s neutral placeholder.
    private func placeholderArt(index: Int, width: CGFloat) -> some View {
        ZStack {
            Color.primary.opacity(0.10)
            VStack(spacing: width * 0.04) {
                Image(systemName: "play.rectangle")
                    .font(.system(size: width * 0.24, weight: .regular))
                    .foregroundStyle(.secondary)
                Text("E\(index + 1)")
                    .font(.system(size: width * 0.15, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
#endif
