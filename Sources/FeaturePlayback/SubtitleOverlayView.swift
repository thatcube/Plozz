#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// Plozz's **own** subtitle renderer: an engine-agnostic SwiftUI overlay that
/// draws a normalized `[SubtitleCue]` stream with full styling.
///
/// This is the keystone of the v2 subtitle architecture. Neither AVPlayer nor
/// Plozzigen (AetherEngine) draws subtitles any more — they emit cues, and this
/// view renders them. That single inversion is what makes HDR-luminance control,
/// live restyling, bitmap subtitles, dual subtitles, offset/sync and (later)
/// word-level features all possible, because we control every pixel.
///
/// It is deliberately **pure data-in**: it has no reference to the player, the
/// engines, or AVFoundation. It takes cues + a ``SubtitleStyle`` and renders.
/// That is why the same view serves both the debug preview harness (mock cues
/// over a backdrop) and, later, live playback (real cues over the video surface)
/// with no changes.
///
/// ### HDR luminance
/// The overlay is an SDR UI layer, so on an HDR display the system already maps
/// its "white" to reference white (~100–203 nits) rather than peak — subtitles
/// don't glare by default. ``SubtitleStyle/hdrLuminanceScale`` then lets the user
/// dim the white point further on HDR frames (a future EDR path can push it
/// brighter). The scale is applied to the text fill and to bitmap cues only on
/// HDR frames; SDR frames are untouched.
public struct SubtitleOverlayView: View {

    /// Cues currently on screen for the primary track (already time-filtered via
    /// `Sequence.active(at:offset:)`). Overlapping cues are allowed.
    public var primary: [SubtitleCue]
    /// Cues for an optional secondary (dual-subtitle) track.
    public var secondary: [SubtitleCue]
    public var style: SubtitleStyle
    /// Whether the underlying video frame is HDR; gates luminance scaling.
    public var isHDR: Bool
    /// The on-screen rect of the video image, used to place bitmap cues. `nil`
    /// means "fill the container" (fine for text and for the harness).
    public var videoRect: CGRect?

    public init(
        primary: [SubtitleCue],
        secondary: [SubtitleCue] = [],
        style: SubtitleStyle,
        isHDR: Bool = false,
        videoRect: CGRect? = nil
    ) {
        self.primary = primary
        self.secondary = secondary
        self.style = style
        self.isHDR = isHDR
        self.videoRect = videoRect
    }

    /// Base point size of subtitle text at `fontScale == 1.0`, tuned for the
    /// 10-foot tvOS experience.
    private static let baseFontSize: CGFloat = 42

    private var lumaScale: Double { isHDR ? style.hdrLuminanceScale : 1.0 }

    public var body: some View {
        GeometryReader { geo in
            let rect = videoRect ?? CGRect(origin: .zero, size: geo.size)
            ZStack {
                bitmapLayer(in: rect)
                textLayer(in: geo.size)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .opacity(style.opacity)          // master opacity: text + bg + edge together
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - Bitmap cues (PGS / DVB / DVD)

    @ViewBuilder
    private func bitmapLayer(in rect: CGRect) -> some View {
        ForEach(primary.filter(\.isImage)) { cue in
            if case .image(let img) = cue.body {
                let r = img.normalizedRect
                let w = max(1, r.width * rect.width)
                let h = max(1, r.height * rect.height)
                Image(decorative: img.cgImage, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: w, height: h)
                    .position(
                        x: rect.minX + (r.midX * rect.width),
                        y: rect.minY + (r.midY * rect.height)
                    )
                    // HDR-only luminance clamp on the bitmap (white-multiply dims).
                    .colorMultiply(Color(white: lumaScale))
            }
        }
    }

    // MARK: - Text cues (primary + secondary)

    @ViewBuilder
    private func textLayer(in size: CGSize) -> some View {
        let primaryText = primary.filter { !$0.isImage }
        let alignment = blockVerticalAlignment(for: primaryText)

        VStack(spacing: style.secondary?.gap ?? 6) {
            if style.secondary?.placement == .above {
                secondaryBlock()
            }
            primaryBlock(primaryText)
            if secondary.isEmpty == false, style.secondary?.placement != .above {
                secondaryBlock()
            }
        }
        .frame(maxWidth: size.width * 0.92, alignment: .center)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment.frameAlignment)
        .padding(.bottom, alignment == .bottom ? size.height * style.verticalPosition : 0)
        .padding(.top, alignment == .top ? size.height * style.verticalPosition : 0)
        .offset(x: style.horizontalOffset * (size.width * 0.25))
    }

    @ViewBuilder
    private func primaryBlock(_ cues: [SubtitleCue]) -> some View {
        VStack(spacing: 2) {
            ForEach(cues) { cue in
                if case .text(let t) = cue.body {
                    StyledCueText(
                        text: t,
                        fontSize: Self.baseFontSize * style.fontScale,
                        fillColor: scaled(style.textColor),
                        style: style
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func secondaryBlock() -> some View {
        if let sec = style.secondary {
            VStack(spacing: 2) {
                ForEach(secondary.filter { !$0.isImage }) { cue in
                    if case .text(let t) = cue.body {
                        StyledCueText(
                            text: t,
                            fontSize: Self.baseFontSize * style.fontScale * sec.relativeScale,
                            fillColor: scaled(sec.textColor),
                            style: style
                        )
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    /// Honour an explicit alignment from the first positioned cue (ASS signs /
    /// captions); otherwise default to bottom.
    private func blockVerticalAlignment(for cues: [SubtitleCue]) -> BlockAlignment {
        for cue in cues {
            if case .text(let t) = cue.body, let a = t.alignment {
                switch a.vertical {
                case .top: return .top
                case .middle: return .middle
                case .bottom: return .bottom
                }
            }
        }
        return .bottom
    }

    /// Apply the HDR luminance scale to a colour (no-op on SDR frames).
    private func scaled(_ c: SubtitleStyle.Color) -> Color {
        let k = lumaScale
        return Color(.sRGB, red: c.red * k, green: c.green * k, blue: c.blue * k, opacity: c.alpha)
    }

    private enum BlockAlignment {
        case top, middle, bottom
        var frameAlignment: Alignment {
            switch self {
            case .top: return .top
            case .middle: return .center
            case .bottom: return .bottom
            }
        }
    }
}

// MARK: - A single styled cue line (background, edge, border, glyphs)

/// Draws one text cue with background box, edge treatment and optional explicit
/// border. Outlines are emulated by stacking the glyphs in eight directions —
/// SwiftUI `Text` has no native stroke — which reads cleanly at couch distance.
private struct StyledCueText: View {
    let text: SubtitleText
    let fontSize: CGFloat
    let fillColor: Color
    let style: SubtitleStyle

    private var font: Font {
        .system(size: fontSize, weight: text.isBold ? .heavy : .semibold)
    }

    var body: some View {
        content
            .padding(.horizontal, style.background.isEnabled ? style.background.horizontalPadding : 0)
            .padding(.vertical, style.background.isEnabled ? style.background.verticalPadding : 0)
            .background {
                if style.background.isEnabled {
                    RoundedRectangle(cornerRadius: style.background.cornerRadius, style: .continuous)
                        .fill(style.background.color.swiftUIColor)
                }
            }
    }

    /// Compose the fill glyphs with edge (shadow / raised / depressed / uniform
    /// outline) and an optional explicit border, both emulated as offset copies.
    /// Built from a reusable `glyphs(_:)` so each copy is a fresh `Text` chain
    /// rather than a shared, already-erased view.
    @ViewBuilder
    private var content: some View {
        let outlineWidth = uniformOutlineWidth
        ZStack {
            if let outlineColor, outlineWidth > 0 {
                ForEach(0..<Self.eightDirections.count, id: \.self) { i in
                    let dir = Self.eightDirections[i]
                    glyphs(outlineColor)
                        .offset(x: dir.0 * outlineWidth, y: dir.1 * outlineWidth)
                }
            }
            applyDirectionalEdge(glyphs(fillColor))
        }
    }

    private func glyphs(_ color: Color) -> some View {
        Text(text.string)
            .font(font)
            .italic(text.isItalic)
            .foregroundStyle(color)
            .multilineTextAlignment(.center)
            .lineLimit(4)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Width of a uniform outline, taken from an explicit border or a `.uniform`
    /// edge style (whichever is larger).
    private var uniformOutlineWidth: CGFloat {
        var w: CGFloat = 0
        if style.border.isEnabled { w = max(w, style.border.width) }
        if style.edge.style == .uniform { w = max(w, style.edge.thickness) }
        return w
    }

    private var outlineColor: Color? {
        if style.border.isEnabled { return style.border.color.swiftUIColor }
        if style.edge.style == .uniform { return style.edge.color.swiftUIColor }
        return nil
    }

    /// Drop-shadow / raised / depressed edges are directional and ride on top of
    /// any uniform outline.
    @ViewBuilder
    private func applyDirectionalEdge(_ v: some View) -> some View {
        let c = style.edge.color.swiftUIColor
        let t = style.edge.thickness
        switch style.edge.style {
        case .none, .uniform:
            v
        case .dropShadow:
            v.shadow(color: c, radius: t, x: t * 0.6, y: t * 0.6)
        case .raised:
            v.shadow(color: c, radius: 0, x: t, y: t)
        case .depressed:
            v.shadow(color: c, radius: 0, x: -t, y: -t)
        }
    }

    private static let eightDirections: [(CGFloat, CGFloat)] = [
        (-1, -1), (0, -1), (1, -1),
        (-1, 0),           (1, 0),
        (-1, 1), (0, 1), (1, 1)
    ]
}
#endif
