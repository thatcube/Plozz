#if canImport(SwiftUI)
import SwiftUI
import UIKit
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

    /// Fraction of the container kept as a title-safe margin for edge-anchored
    /// cues, so ASS signs near a screen edge aren't lost to tvOS overscan.
    private static let titleSafeFraction: CGFloat = 0.05

    @ViewBuilder
    private func textLayer(in size: CGSize) -> some View {
        let text = primary.filter { !$0.isImage }
        // A cue with an explicit alignment is a positioned sign/caption and is
        // placed independently. Everything else is dialogue and shares the user's
        // configured default seat — so a top sign never drags dialogue with it.
        let positioned = text.filter { cueAlignment($0) != nil }
        let dialogue = text.filter { cueAlignment($0) == nil }

        ZStack {
            // Default dialogue: primary dialogue lines + the dual-sub secondary,
            // seated just above the bottom safe edge (user-adjustable). Multiple
            // simultaneous lines stack here rather than overlapping.
            dialogueStack(dialogue)
                .frame(maxWidth: size.width * 0.92, alignment: .center)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, size.height * style.verticalPosition)
                .offset(x: style.horizontalOffset * (size.width * 0.25))

            // Positioned cues (ASS signs / captions): each honours its own `\an`
            // plane independently, inset from the edges by a title-safe margin.
            ForEach(positioned) { cue in
                if case .text(let t) = cue.body, let a = t.alignment {
                    StyledCueText(
                        text: t,
                        fontSize: Self.baseFontSize * style.fontScale,
                        fillColor: scaled(style.textColor),
                        textAlignment: a.textAlignment,
                        style: style
                    )
                    .frame(maxWidth: size.width * 0.92, alignment: a.frameTextAlignment)
                    .padding(.horizontal, size.width * Self.titleSafeFraction)
                    .padding(.vertical, size.height * Self.titleSafeFraction)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: a.planeAlignment)
                }
            }
        }
    }

    /// The shared default-position stack: primary dialogue plus the optional
    /// secondary (dual-subtitle) block, ordered per ``SubtitleStyle/Secondary``.
    @ViewBuilder
    private func dialogueStack(_ dialogue: [SubtitleCue]) -> some View {
        VStack(spacing: style.secondary?.gap ?? 6) {
            if style.secondary?.placement == .above {
                secondaryBlock()
            }
            primaryBlock(dialogue)
            if secondary.isEmpty == false, style.secondary?.placement != .above {
                secondaryBlock()
            }
        }
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
            // Default: the secondary line inherits the primary look (colour +
            // size) so dual subs read as one system. `differentiate` opts into a
            // distinct colour/size for language-learning clarity.
            let secFill = sec.differentiate ? scaled(sec.textColor) : scaled(style.textColor)
            let secScale = sec.differentiate ? sec.relativeScale : 1.0
            VStack(spacing: 2) {
                ForEach(secondary.filter { !$0.isImage }) { cue in
                    if case .text(let t) = cue.body {
                        StyledCueText(
                            text: t,
                            fontSize: Self.baseFontSize * style.fontScale * secScale,
                            fillColor: secFill,
                            style: style
                        )
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func cueAlignment(_ cue: SubtitleCue) -> SubtitleAlignment? {
        if case .text(let t) = cue.body { return t.alignment }
        return nil
    }

    /// Apply the HDR luminance scale to a colour (no-op on SDR frames).
    private func scaled(_ c: SubtitleStyle.Color) -> Color {
        let k = lumaScale
        return Color(.sRGB, red: c.red * k, green: c.green * k, blue: c.blue * k, opacity: c.alpha)
    }
}

// MARK: - ASS `\an` plane → SwiftUI placement

private extension SubtitleAlignment {
    /// The container-fill alignment that pins a positioned cue to its `\an` plane.
    var planeAlignment: Alignment {
        let h: HorizontalAlignment
        switch horizontal {
        case .leading: h = .leading
        case .center: h = .center
        case .trailing: h = .trailing
        }
        let v: VerticalAlignment
        switch vertical {
        case .top: v = .top
        case .middle: v = .center
        case .bottom: v = .bottom
        }
        return Alignment(horizontal: h, vertical: v)
    }

    /// Multi-line justification within a positioned cue's own box.
    var textAlignment: TextAlignment {
        switch horizontal {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    /// Horizontal seat of the cue box inside its max-width frame.
    var frameTextAlignment: Alignment {
        switch horizontal {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}

// MARK: - A single styled cue line (background, edge, border, glyphs)

/// Draws one text cue with background box, edge treatment and optional explicit
/// border. Outlines use a **true continuous stroke** (UIKit `NSAttributedString`
/// stroke attributes) so they stay clean at any thickness, and read well at
/// couch distance.
private struct StyledCueText: View {
    let text: SubtitleText
    let fontSize: CGFloat
    let fillColor: Color
    var textAlignment: TextAlignment = .center
    let style: SubtitleStyle

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

    /// The glyphs with a **true continuous outline** (explicit border / `.uniform`
    /// edge) plus the directional edge (drop shadow / raised / depressed). The
    /// outline is drawn by UIKit via `NSAttributedString` stroke attributes —
    /// unlike the old eight-way offset-stamp, this stays an unbroken stroke at
    /// any thickness instead of separating into dots.
    @ViewBuilder
    private var content: some View {
        applyDirectionalEdge(
            OutlinedText(
                text: text.string,
                fontSize: fontSize,
                isBold: text.isBold,
                isItalic: text.isItalic,
                fill: fillColor,
                stroke: outlineColor,
                strokeWidth: uniformOutlineWidth,
                alignment: textAlignment,
                maxLines: 4
            )
        )
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
}

// MARK: - UIKit-backed outlined text (true continuous stroke)

/// Renders a subtitle line with a real, continuous outline via
/// `NSAttributedString` stroke attributes — the only way to get a clean stroke at
/// any width on tvOS, since SwiftUI `Text` cannot stroke. Self-sizes (wrapping at
/// the proposed width) so the background box and surrounding layout still fit the
/// glyphs exactly.
private struct OutlinedText: UIViewRepresentable {
    let text: String
    let fontSize: CGFloat
    let isBold: Bool
    let isItalic: Bool
    let fill: Color
    let stroke: Color?
    let strokeWidth: CGFloat
    let alignment: TextAlignment
    let maxLines: Int

    func makeUIView(context: Context) -> UILabel {
        let l = UILabel()
        l.backgroundColor = .clear
        l.isOpaque = false
        l.lineBreakMode = .byWordWrapping
        l.setContentHuggingPriority(.required, for: .horizontal)
        l.setContentHuggingPriority(.required, for: .vertical)
        return l
    }

    func updateUIView(_ l: UILabel, context: Context) {
        l.numberOfLines = maxLines
        l.textAlignment = nsAlignment
        l.attributedText = attributed
        l.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UILabel, context: Context) -> CGSize? {
        let maxW = proposal.width.map { $0.isFinite ? $0 : 10_000 } ?? 10_000
        uiView.preferredMaxLayoutWidth = maxW
        let fit = uiView.sizeThatFits(CGSize(width: maxW, height: .greatestFiniteMagnitude))
        return CGSize(width: min(fit.width, maxW), height: fit.height)
    }

    private var uiFont: UIFont {
        var f = UIFont.systemFont(ofSize: fontSize, weight: isBold ? .heavy : .semibold)
        if isItalic, let d = f.fontDescriptor.withSymbolicTraits(.traitItalic) {
            f = UIFont(descriptor: d, size: fontSize)
        }
        return f
    }

    private var nsAlignment: NSTextAlignment {
        switch alignment {
        case .leading: return .left
        case .trailing: return .right
        default: return .center
        }
    }

    private var attributed: NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.alignment = nsAlignment
        para.lineBreakMode = .byWordWrapping
        var attrs: [NSAttributedString.Key: Any] = [
            .font: uiFont,
            .foregroundColor: UIColor(fill),
            .paragraphStyle: para
        ]
        if let stroke, strokeWidth > 0 {
            attrs[.strokeColor] = UIColor(stroke)
            // `.strokeWidth` is a percentage of font size; a *negative* value
            // means "fill *and* stroke" (positive would hollow the glyphs).
            attrs[.strokeWidth] = -Double(strokeWidth / fontSize * 100)
        }
        return NSAttributedString(string: text, attributes: attrs)
    }
}
#endif
