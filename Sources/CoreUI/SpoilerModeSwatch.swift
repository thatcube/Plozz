#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// A small, self-contained preview of how a spoiler-hidden episode looks in each
/// ``SpoilerSettings/Mode`` — mirroring the real `PosterCardView` treatment:
/// **Blur** shows the real still, blurred; **Placeholder** swaps in generic art
/// with the episode number so not even a blurred frame leaks. Both modes also
/// keep the title/description hidden until watched, shown here as redacted bars.
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

    public var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            VStack(alignment: .leading, spacing: h * 0.08) {
                thumbnail(width: w)
                    .frame(maxWidth: .infinity)
                    .frame(height: h * 0.62)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(Color(white: 0.5).opacity(0.3), lineWidth: 1)
                    )

                // Title + description are hidden in BOTH modes — shown as the
                // "redacted" bars a masked episode card renders in their place.
                redactedBar(width: w * 0.58, height: max(6, h * 0.06))
                redactedBar(width: w * 0.36, height: max(5, h * 0.05))
            }
            .frame(width: w, height: h, alignment: .top)
        }
    }

    @ViewBuilder
    private func thumbnail(width: CGFloat) -> some View {
        switch mode {
        case .blur:
            fakeStill.blur(radius: width * 0.06)
        case .placeholder:
            placeholderArt
        }
    }

    /// A fabricated "episode still" — a colourful scene so its blurred version
    /// clearly reads as a real (hidden) frame rather than a flat wash.
    private var fakeStill: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.18, green: 0.50, blue: 0.72),
                        Color(red: 0.60, green: 0.26, blue: 0.54)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                RadialGradient(
                    colors: [Color(red: 0.99, green: 0.80, blue: 0.36).opacity(0.9), .clear],
                    center: .init(x: 0.68, y: 0.34),
                    startRadius: 0,
                    endRadius: w * 0.6
                )
            }
        }
    }

    /// The "no real frame" look: a muted fill with a play glyph + episode number,
    /// matching `PosterCardView`'s neutral placeholder.
    private var placeholderArt: some View {
        ZStack {
            Color.primary.opacity(0.10)
            VStack(spacing: 6) {
                Image(systemName: "play.rectangle")
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(.secondary)
                Text("S1 · E4")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func redactedBar(width: CGFloat, height: CGFloat) -> some View {
        Capsule()
            .fill(Color.primary.opacity(0.16))
            .frame(width: width, height: height)
    }
}
#endif
