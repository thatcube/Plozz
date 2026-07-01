#if canImport(SwiftUI)
import SwiftUI
import UIKit
import CoreText
import CoreGraphics
import CoreModels

/// A soft drop / hard directional shadow for the subtitle renderer.
struct SubtitleShadowSpec: Equatable {
    var offset: CGSize
    var blur: CGFloat
    var color: UIColor
}

/// An optional rounded background box drawn *behind* one subtitle line. It is
/// rendered inside ``CoreTextSubtitleLine`` (not as a SwiftUI `.background`) so it
/// hugs the text box at the user's padding while the view itself can extend well
/// past it for big outlines/shadows without clipping or a loose-looking box.
struct SubtitleBackgroundSpec: Equatable {
    var color: UIColor
    var cornerRadius: CGFloat
    var horizontalPadding: CGFloat
    var verticalPadding: CGFloat
}

/// SwiftUI wrapper around a Core Text **glyph-path** subtitle line.
///
/// Outlines are drawn with the canonical **stroke-behind / fill-on-top**
/// technique used by libass and VLC: each glyph's real vector outline
/// (`CTFontCreatePathForGlyph`) is collected into one path, stroked in the
/// outline colour at **twice** the visible width with round joins/caps, and then
/// the fill is painted on top — so only the *outer* half of the stroke shows.
///
/// This is the fix for the old centered `NSAttributedString.strokeWidth`, which
/// grows half-*inward*: it ate the glyph fill and turned letters solid black as
/// the width increased. A path stroke behind the fill can never do that.
///
/// The view self-sizes (wrapping at the proposed width) and pads itself so the
/// outer outline and shadow are never clipped. It also drives the **CJK font
/// cascade** (Hiragino / PingFang / Apple SD Gothic Neo) so mixed-language and
/// dual-subtitle lines render with the bundled Latin face *and* system CJK.
struct CoreTextSubtitleLine: UIViewRepresentable {
    let text: String
    let family: SubtitleFontFamily
    let weight: SubtitleFontWeight
    let fontSize: CGFloat
    let isBold: Bool
    let isItalic: Bool
    let fill: UIColor
    let outline: UIColor?
    /// Visible outline width in points (the renderer strokes at 2× this).
    let outlineWidth: CGFloat
    let shadow: SubtitleShadowSpec?
    let background: SubtitleBackgroundSpec?
    let alignment: NSTextAlignment

    func makeUIView(context: Context) -> SubtitleLineView { SubtitleLineView() }

    func updateUIView(_ view: SubtitleLineView, context: Context) {
        view.configure(SubtitleLineView.Config(
            text: text, family: family, weight: weight, fontSize: fontSize,
            isBold: isBold, isItalic: isItalic,
            fill: fill, outline: outline, outlineWidth: outlineWidth,
            shadow: shadow, background: background, alignment: alignment))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: SubtitleLineView, context: Context) -> CGSize? {
        let w = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 10_000
        return uiView.measure(maxWidth: w)
    }
}

/// UIKit view that lays out one subtitle line with Core Text and draws it with a
/// proper outer outline. Layout (the expensive part — shaping + glyph-path
/// extraction) is cached and only rebuilt when the config or wrap width changes,
/// so a 60 fps `TimelineView` redraw just re-fills a cached `CGPath`.
final class SubtitleLineView: UIView {

    struct Config: Equatable {
        var text: String
        var family: SubtitleFontFamily
        var weight: SubtitleFontWeight
        var fontSize: CGFloat
        var isBold: Bool
        var isItalic: Bool
        var fill: UIColor
        var outline: UIColor?
        var outlineWidth: CGFloat
        var shadow: SubtitleShadowSpec?
        var background: SubtitleBackgroundSpec?
        var alignment: NSTextAlignment
    }

    private struct Layout {
        var path: CGPath          // combined glyph outline, positioned in flipped coords
        var totalSize: CGSize     // text size + outline/shadow/background insets
        var colorGlyphs: [ColorGlyph]  // emoji / colour glyphs (no vector path) drawn on top
        var background: BackgroundFill?  // rounded box hugging the text, drawn first
    }

    /// A resolved background box in the line's flipped drawing coordinates.
    private struct BackgroundFill {
        var rect: CGRect
        var color: UIColor
        var cornerRadius: CGFloat
    }

    /// A colour/bitmap glyph (e.g. emoji) that exposes no vector outline and so
    /// must be drawn directly rather than stroked/filled as part of the path.
    private struct ColorGlyph {
        var font: CTFont
        var glyph: CGGlyph
        var position: CGPoint
    }

    private var config: Config?
    private var layout: Layout?
    private var layoutWidth: CGFloat = -1

    override init(frame: CGRect) { super.init(frame: frame); commonInit() }
    required init?(coder: NSCoder) { super.init(coder: coder); commonInit() }
    private func commonInit() {
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    func configure(_ c: Config) {
        guard c != config else { return }
        config = c
        layout = nil
        layoutWidth = -1
        invalidateIntrinsicContentSize()
        setNeedsDisplay()
    }

    func measure(maxWidth: CGFloat) -> CGSize {
        guard let c = config else { return .zero }
        if let l = layout, layoutWidth == maxWidth { return l.totalSize }
        let l = buildLayout(c, maxWidth: maxWidth)
        layout = l
        layoutWidth = maxWidth
        return l.totalSize
    }

    override var intrinsicContentSize: CGSize {
        layout?.totalSize ?? CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        measure(maxWidth: size.width)
    }

    override func draw(_ rect: CGRect) {
        guard let c = config, let ctx = UIGraphicsGetCurrentContext() else { return }
        let l: Layout
        if let cached = layout, layoutWidth == bounds.width {
            l = cached
        } else {
            l = buildLayout(c, maxWidth: bounds.width)
            layout = l
            layoutWidth = bounds.width
        }

        ctx.saveGState()
        defer { ctx.restoreGState() }

        // UIKit top-left origin → Core Text / Core Graphics bottom-left origin.
        ctx.textMatrix = .identity
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)

        let path = l.path

        // 0. Background box: drawn first so the shadow, outline and fill all sit
        //    on top. It hugs the text at the user's padding regardless of how far
        //    the outline/shadow overflow extends the view bounds.
        if let bg = l.background {
            let box = UIBezierPath(roundedRect: bg.rect, cornerRadius: bg.cornerRadius).cgPath
            ctx.addPath(box)
            ctx.setFillColor(bg.color.cgColor)
            ctx.fillPath()
        }

        // 1. Soft shadow: fill the glyph silhouette with a live shadow so the
        //    blurred/offset copy shows behind everything else.
        if let sh = c.shadow {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: sh.offset.width, height: -sh.offset.height),
                          blur: sh.blur, color: sh.color.cgColor)
            ctx.addPath(path)
            ctx.setFillColor(c.fill.cgColor)
            ctx.fillPath()
            ctx.restoreGState()
        }

        // 2. Outline *behind* the fill — stroke at 2× the visible width so only
        //    the outer half remains once the fill is painted over it.
        if let outline = c.outline, c.outlineWidth > 0 {
            ctx.saveGState()
            ctx.addPath(path)
            ctx.setStrokeColor(outline.cgColor)
            ctx.setLineWidth(c.outlineWidth * 2)
            ctx.setLineJoin(.round)
            ctx.setLineCap(.round)
            ctx.strokePath()
            ctx.restoreGState()
        }

        // 3. Fill on top.
        ctx.addPath(path)
        ctx.setFillColor(c.fill.cgColor)
        ctx.fillPath()

        // 4. Colour-glyph pass (emoji etc.): these expose no vector outline, so
        //    we draw just those individual glyphs on top. Crucially we do NOT
        //    redraw the whole line — spaces also report "no path", and stamping
        //    the entire frame here is what double-struck the text.
        if !l.colorGlyphs.isEmpty {
            for cg in l.colorGlyphs {
                var g = cg.glyph
                var p = cg.position
                CTFontDrawGlyphs(cg.font, &g, &p, 1, ctx)
            }
        }
    }

    // MARK: - Layout

    private func buildLayout(_ c: Config, maxWidth: CGFloat) -> Layout {
        let font = makeCTFont(c)
        let attr = makeAttributed(c, font: font)
        let fs = CTFramesetterCreateWithAttributedString(attr)

        // How far drawing reaches beyond the glyph ink, per side: the outline is
        // stroked at 2× width centred on the contour, so it extends `outlineWidth`
        // outward; the shadow extends by its blur plus its directional offset; and
        // a generous margin (scaled with the font) absorbs glyph ink that spills
        // past the typographic box — italic lean, CJK/accent side bearings — and
        // gives big borders/shadows room so they are never clipped.
        let strokeOut = max(0, c.outlineWidth)
        let sh = shadowOutsets(c)
        let margin = max(ceil(c.fontSize * 0.2), 8)
        let padL = strokeOut + sh.left + margin
        let padR = strokeOut + sh.right + margin
        let padT = strokeOut + sh.top + margin
        let padB = strokeOut + sh.bottom + margin

        // Reserve the horizontal pad so a full-width line plus its overflow still
        // fits the proposed width (the view never has to exceed `maxWidth`).
        let textMax = max(1, maxWidth - padL - padR)
        var fitRange = CFRange()
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            fs, CFRange(location: 0, length: attr.length), nil,
            CGSize(width: textMax, height: .greatestFiniteMagnitude), &fitRange)
        let textSize = CGSize(width: ceil(min(suggested.width, textMax)),
                              height: ceil(suggested.height))

        // Lay the text out at the origin, then read the *actual* ink bounds.
        let boxRect = CGRect(origin: .zero, size: textSize)
        let frame = CTFramesetterCreateFrame(
            fs, CFRange(location: 0, length: attr.length),
            CGPath(rect: boxRect, transform: nil), nil)
        let (rawPath, rawColorGlyphs) = Self.combinedGlyphPath(frame: frame)

        // Real drawn extent = the typographic box unioned with the vector-glyph
        // ink and any colour-glyph (emoji) boxes. Glyph ink routinely exceeds the
        // advance box, which is the root cause of the edge clipping.
        var ink = boxRect
        if !rawPath.isEmpty { ink = ink.union(rawPath.boundingBoxOfPath) }
        for cg in rawColorGlyphs {
            var g = cg.glyph
            var b = CGRect.zero
            CTFontGetBoundingRectsForGlyphs(cg.font, .default, &g, &b, 1)
            if !b.isNull, b.width > 0, b.height > 0 {
                ink = ink.union(b.offsetBy(dx: cg.position.x, dy: cg.position.y))
            }
        }

        // Grow the ink by the per-side reach to get the full drawn rect, union in
        // the optional background box (which hugs the text box at the user's
        // padding), then shift everything so the result starts at the origin.
        var drawn = CGRect(
            x: ink.minX - padL,
            y: ink.minY - padB,                       // flipped coords: bottom = min y
            width:  ink.width  + padL + padR,
            height: ink.height + padT + padB)
        var bgPre: CGRect?
        if let bg = c.background {
            let r = boxRect.insetBy(dx: -bg.horizontalPadding, dy: -bg.verticalPadding)
            bgPre = r
            drawn = drawn.union(r)
        }
        var shift = CGAffineTransform(translationX: -drawn.minX, y: -drawn.minY)
        let path = rawPath.copy(using: &shift) ?? rawPath
        let colorGlyphs = rawColorGlyphs.map {
            ColorGlyph(font: $0.font, glyph: $0.glyph,
                       position: CGPoint(x: $0.position.x - drawn.minX,
                                         y: $0.position.y - drawn.minY))
        }
        var background: BackgroundFill?
        if let bg = c.background, let r = bgPre {
            background = BackgroundFill(
                rect: r.offsetBy(dx: -drawn.minX, dy: -drawn.minY),
                color: bg.color, cornerRadius: bg.cornerRadius)
        }
        return Layout(path: path,
                      totalSize: CGSize(width: ceil(drawn.width), height: ceil(drawn.height)),
                      colorGlyphs: colorGlyphs,
                      background: background)
    }

    /// How far the soft shadow reaches beyond the glyph ink on each side. `draw`
    /// negates the vertical offset (UIKit→Core Text flip), so a positive
    /// `offset.height` pushes the shadow toward the view's bottom.
    private func shadowOutsets(_ c: Config) -> UIEdgeInsets {
        guard let sh = c.shadow else { return .zero }
        let blur = max(0, sh.blur)
        return UIEdgeInsets(
            top:    blur + max(0, -sh.offset.height),
            left:   blur + max(0, -sh.offset.width),
            bottom: blur + max(0,  sh.offset.height),
            right:  blur + max(0,  sh.offset.width))
    }

    private static func combinedGlyphPath(frame: CTFrame) -> (CGPath, [ColorGlyph]) {
        let combined = CGMutablePath()
        var colorGlyphs: [ColorGlyph] = []
        guard let lines = CTFrameGetLines(frame) as? [CTLine] else { return (combined, []) }
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)

        for (i, line) in lines.enumerated() {
            let lineOrigin = origins[i]
            guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { continue }
            for run in runs {
                let attrs = CTRunGetAttributes(run) as NSDictionary
                guard let runFontRaw = attrs[kCTFontAttributeName] else { continue }
                // CTFont is a Core Foundation class; this cast always succeeds.
                let runFont = runFontRaw as! CTFont
                let count = CTRunGetGlyphCount(run)
                if count == 0 { continue }
                var glyphs = [CGGlyph](repeating: 0, count: count)
                var positions = [CGPoint](repeating: .zero, count: count)
                CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
                CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
                for j in 0..<count {
                    let pos = CGPoint(x: lineOrigin.x + positions[j].x,
                                      y: lineOrigin.y + positions[j].y)
                    if let gp = CTFontCreatePathForGlyph(runFont, glyphs[j], nil) {
                        combined.addPath(gp, transform: CGAffineTransform(translationX: pos.x, y: pos.y))
                        continue
                    }
                    // No vector outline. This is *usually* whitespace (a space has
                    // no contour) — which must be ignored, not drawn. Only a glyph
                    // with actual ink but no path (a colour/emoji glyph) needs the
                    // direct-draw pass, so distinguish them by ink bounds.
                    var g = glyphs[j]
                    var inkBounds = CGRect.zero
                    CTFontGetBoundingRectsForGlyphs(runFont, .default, &g, &inkBounds, 1)
                    if inkBounds.width > 0 && inkBounds.height > 0 {
                        colorGlyphs.append(ColorGlyph(font: runFont, glyph: glyphs[j], position: pos))
                    }
                }
            }
        }
        return (combined, colorGlyphs)
    }

    // MARK: - Font

    /// The bundled-face PostScript name for the requested weight/slant, or `nil`
    /// to use the system font. Picks the closest face a family actually bundles:
    /// italic is preserved first (families ship italics only at Regular/Bold, and
    /// italic is per-cue emphasis), then the weight degrades toward Regular rather
    /// than letting Core Text substitute an unrelated system font.
    private func postScriptName(_ c: Config) -> String? {
        guard let stem = c.family.postScriptStem else { return nil }
        let weight = effectiveWeight(c)
        let available = c.family.availableWeights
        var candidates: [String] = []
        // Keep the slant first when the cue is italic (only Regular/Bold italics
        // are bundled), so emphasis survives even if the exact weight can't.
        if c.isItalic {
            if weight == .bold { candidates.append("\(stem)-BoldItalic") }
            candidates.append("\(stem)-Italic")
        }
        // Upright faces from the effective weight down to Regular.
        let downChain = available.filter { $0.value <= weight.value }.sorted { $0.value > $1.value }
        for w in downChain { candidates.append("\(stem)-\(w.faceToken)") }
        if !downChain.contains(.regular) { candidates.append("\(stem)-Regular") }
        return candidates.first { UIFont(name: $0, size: 12) != nil } ?? "\(stem)-Regular"
    }

    /// The weight to actually render for this cue: the global weight snapped to
    /// what the family bundles, bumped to the family's heaviest face when the cue
    /// itself is bold (per-cue markup), never lighter than the chosen base.
    private func effectiveWeight(_ c: Config) -> SubtitleFontWeight {
        let available = c.family.availableWeights
        let base = c.weight.snapped(to: available)
        guard c.isBold else { return base }
        let heaviest = available.last ?? .bold
        return heaviest.value >= base.value ? heaviest : base
    }

    private func uiFontWeight(_ w: SubtitleFontWeight) -> UIFont.Weight {
        switch w {
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        }
    }

    /// tvOS system fonts that cover CJK + emoji, appended as a Core Text cascade
    /// list so the Latin face falls back per-glyph for mixed-script lines.
    private static let cjkFallbackNames = [
        "HiraginoSans-W6", "HiraginoSans-W5", "HiraginoSans-W3",
        "AppleSDGothicNeo-SemiBold", "AppleSDGothicNeo-Medium", "AppleSDGothicNeo-Regular",
        "PingFangSC-Medium", "PingFangSC-Semibold", "PingFangSC-Regular",
        "PingFangTC-Medium", "PingFangHK-Medium",
        "AppleColorEmoji"
    ]

    private func makeCTFont(_ c: Config) -> CTFont {
        let size = c.fontSize
        let baseDescriptor: CTFontDescriptor
        if let ps = postScriptName(c) {
            baseDescriptor = CTFontDescriptorCreateWithNameAndSize(ps as CFString, size)
            #if DEBUG
            // Core Text silently substitutes a fallback when a named font isn't
            // registered, so a missing UIAppFonts entry / unbundled face would
            // render every cue in the wrong font with no error. Surface it.
            let resolved = CTFontCopyPostScriptName(
                CTFontCreateWithFontDescriptor(baseDescriptor, size, nil)) as String
            if resolved.caseInsensitiveCompare(ps) != .orderedSame {
                print("⚠️ [Subtitle] requested font '\(ps)' but Core Text resolved '\(resolved)' — check UIAppFonts + that the TTF is bundled; subtitles are NOT using the intended face.")
            }
            #endif
        } else {
            let ui = UIFont.systemFont(ofSize: size, weight: uiFontWeight(effectiveWeight(c)))
            var descriptor = ui.fontDescriptor
            // SF Rounded: adopt the rounded design while preserving the weight.
            if c.family.usesRoundedDesign, let d = descriptor.withDesign(.rounded) {
                descriptor = d
            }
            if c.isItalic,
               let d = descriptor.withSymbolicTraits([descriptor.symbolicTraits, .traitItalic]) {
                descriptor = d
            }
            baseDescriptor = UIFont(descriptor: descriptor, size: size).fontDescriptor as CTFontDescriptor
        }
        let cascade = Self.cjkFallbackNames.map {
            CTFontDescriptorCreateWithNameAndSize($0 as CFString, size)
        }
        let withCascade = CTFontDescriptorCreateCopyWithAttributes(
            baseDescriptor,
            [kCTFontCascadeListAttribute: cascade] as CFDictionary)
        return CTFontCreateWithFontDescriptor(withCascade, size, nil)
    }

    private func makeAttributed(_ c: Config, font: CTFont) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.alignment = c.alignment
        para.lineBreakMode = .byWordWrapping
        return NSAttributedString(string: c.text, attributes: [
            kCTFontAttributeName as NSAttributedString.Key: font,
            .foregroundColor: c.fill,
            .paragraphStyle: para
        ])
    }
}
#endif
