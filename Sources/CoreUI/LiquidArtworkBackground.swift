#if canImport(SwiftUI)
import SwiftUI

/// An Apple Music–style morphing "liquid" background tinted to the prominent
/// colors of the current album art. The colors slowly drift and blend into one
/// another so the screen feels alive without ever distracting from the artwork,
/// track info, or lyrics layered on top.
///
/// On tvOS 18+ this is a `MeshGradient` whose interior control points wander on
/// slow, out-of-phase sine waves — the corners stay pinned so the gradient
/// always fills the screen while the middle of the mesh churns, producing the
/// fluid, paint-in-water look. On older systems it falls back to a few large,
/// heavily-blurred color blobs that drift around and blend.
///
/// A dark scrim and gentle vignette are layered on top so foreground text and
/// lyrics keep their contrast regardless of how bright the artwork is. When
/// `palette` is empty (no artwork yet) it shows a calm neutral dark field.
public struct LiquidArtworkBackground: View {
    /// Prominent colors, most significant first. May be empty.
    public var palette: [Color]
    /// When false (Reduce Motion) the gradient is rendered statically.
    public var animate: Bool = true
    /// How the scrim over the morphing colors is painted.
    public var style: Style = .dark

    /// The three background treatments the player offers.
    public enum Style { case dark, light, oled }

    public init(palette: [Color], animate: Bool = true, style: Style = .dark) {
        self.palette = palette
        self.animate = animate
        self.style = style
    }

    public var body: some View {
        ZStack {
            base
            gradientLayer
                .ignoresSafeArea()
                .opacity(gradientOpacity)
            scrim
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 1.2), value: palette)
    }

    /// The solid floor under the morphing colors.
    private var base: some View {
        (style == .light ? Color.white : Color.black)
    }

    /// How strongly the artwork colors show through, per style.
    private var gradientOpacity: Double {
        switch style {
        case .dark: return 1.0
        case .light: return 0.95
        case .oled: return 0.5
        }
    }

    /// Per-style legibility layers: dark veils + vignette for dark/OLED, a light
    /// veil for the frosted look. Keeps foreground text readable regardless of
    /// how bright or busy the artwork is.
    @ViewBuilder
    private var scrim: some View {
        switch style {
        case .dark:
            Color.black.opacity(0.32)
            RadialGradient(colors: [.clear, Color.black.opacity(0.45)],
                           center: .center, startRadius: 200, endRadius: 1400)
            LinearGradient(colors: [.clear, .clear, Color.black.opacity(0.35)],
                           startPoint: .top, endPoint: .bottom)
        case .oled:
            // Push almost everything to true black, leaving the colors as faint
            // accents — easy on OLED panels and very high contrast.
            Color.black.opacity(0.6)
            RadialGradient(colors: [.clear, Color.black.opacity(0.78)],
                           center: .center, startRadius: 160, endRadius: 1400)
            LinearGradient(colors: [.clear, .clear, Color.black.opacity(0.55)],
                           startPoint: .top, endPoint: .bottom)
        case .light:
            // A light frosted veil lifts the field just enough for dark text
            // while letting the artwork color read clearly through it.
            Color.white.opacity(0.32)
            RadialGradient(colors: [.clear, Color.white.opacity(0.18)],
                           center: .center, startRadius: 240, endRadius: 1400)
            LinearGradient(colors: [.clear, .clear, Color.white.opacity(0.2)],
                           startPoint: .top, endPoint: .bottom)
        }
    }

    @ViewBuilder
    private var gradientLayer: some View {
        let colors = resolvedColors
        if #available(tvOS 18.0, *) {
            MeshLiquidLayer(colors: colors, animate: animate)
        } else {
            BlobLiquidLayer(colors: colors, animate: animate)
        }
    }

    /// Always hand the layers at least a few colors so the gradient has
    /// something to morph between, padding short palettes by cycling.
    private var resolvedColors: [Color] {
        let base = palette.isEmpty ? Self.neutral : palette
        guard base.count < 5 else { return base }
        var padded = base
        var i = 0
        while padded.count < 5 {
            padded.append(base[i % base.count])
            i += 1
        }
        return padded
    }

    /// Calm neutral field used before any artwork color is known.
    private static let neutral: [Color] = [
        Color(red: 0.10, green: 0.11, blue: 0.14),
        Color(red: 0.16, green: 0.17, blue: 0.22),
        Color(red: 0.08, green: 0.09, blue: 0.12),
        Color(red: 0.13, green: 0.14, blue: 0.18)
    ]
}

// MARK: - tvOS 18+ mesh

@available(tvOS 18.0, *)
private struct MeshLiquidLayer: View {
    var colors: [Color]
    var animate: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !animate)) { context in
            let t = animate ? context.date.timeIntervalSinceReferenceDate : 0
            MeshGradient(
                width: 3,
                height: 3,
                points: points(at: t),
                colors: meshColors,
                smoothsColors: true
            )
        }
    }

    /// Nine colors for the 3×3 mesh, most prominent color anchored in the center
    /// with the rest spread around it. `colors` is guaranteed ≥ 5 by the parent.
    private var meshColors: [Color] {
        let c = colors
        return [
            c[1], c[2], c[3],
            c[4], c[0], c[1],
            c[2], c[3], c[4]
        ]
    }

    /// The 3×3 control points. The four corners are pinned so the gradient always
    /// fills the rect; the edge midpoints slide along their edges and the center
    /// roams freely, each on its own slow period for an organic, non-repeating
    /// drift. Amplitudes stay clear of the pinned corners so the mesh never folds,
    /// but are large enough to give the field visible, lively motion.
    private func points(at t: TimeInterval) -> [SIMD2<Float>] {
        func osc(_ period: Double, _ phase: Double) -> Float {
            Float(sin(t / period + phase))
        }
        return [
            SIMD2(0, 0),
            SIMD2(0.5 + 0.20 * osc(9, 0.0), 0.0),
            SIMD2(1, 0),

            SIMD2(0.0, 0.5 + 0.20 * osc(10.5, 1.3)),
            SIMD2(0.5 + 0.26 * osc(7.5, 0.7), 0.5 + 0.26 * osc(9.5, 2.1)),
            SIMD2(1.0, 0.5 + 0.20 * osc(8, 3.4)),

            SIMD2(0, 1),
            SIMD2(0.5 + 0.20 * osc(11, 4.2), 1.0),
            SIMD2(1, 1)
        ]
    }
}

// MARK: - tvOS 17 fallback

private struct BlobLiquidLayer: View {
    var colors: [Color]
    var animate: Bool

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !animate)) { context in
                let t = animate ? context.date.timeIntervalSinceReferenceDate : 0
                let size = proxy.size
                ZStack {
                    ForEach(Array(colors.prefix(5).enumerated()), id: \.offset) { index, color in
                        Circle()
                            .fill(color)
                            .frame(width: size.width * 0.85, height: size.width * 0.85)
                            .position(position(index: index, in: size, t: t))
                            .blendMode(.plusLighter)
                    }
                }
                .blur(radius: 140)
                .opacity(0.85)
            }
        }
    }

    private func position(index: Int, in size: CGSize, t: TimeInterval) -> CGPoint {
        let period = 10.0 + Double(index) * 2.5
        let phase = Double(index) * 1.7
        let x = 0.5 + 0.32 * sin(t / period + phase)
        let y = 0.5 + 0.32 * cos(t / (period * 1.2) + phase)
        return CGPoint(x: x * size.width, y: y * size.height)
    }
}
#endif
