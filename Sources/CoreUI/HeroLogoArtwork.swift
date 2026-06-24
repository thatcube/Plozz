#if canImport(SwiftUI)
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// A colour sample of the hero artwork behind the logo: the mean colour of the
/// sampled region plus its luminance. Used to decide whether a logo needs a
/// legibility halo — the decision weighs both brightness *and* colour, so a
/// vibrant logo (e.g. a saturated red wordmark) isn't haloed just because its
/// luminance happens to sit near the backdrop's.
public struct HeroBackgroundSample: Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let luminance: Double

    public init(red: Double, green: Double, blue: Double, luminance: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.luminance = luminance
    }
}

/// Renders a show's stylized title/logo art for the detail hero, falling back to
/// a plain text title when no logo can be found.
///
/// Resolution order:
///   1. `primaryURL` — the provider's own `Logo` image (e.g. Jellyfin).
///   2. `asyncFallbackURL` — a TMDb logo lookup, used only when the provider has
///      no usable logo.
///   3. `textFallback` — the caller's styled title `Text`, shown when nothing
///      resolves (or on platforms without UIKit image decoding).
///
/// The logo is fit (never cropped) inside a `maxWidth` × `maxHeight` box, pinned
/// to the leading edge, and fades in once decoded. Unlike poster art there is no
/// aspect-ratio guard — logos are legitimately wide.
public struct HeroLogoArtwork<TextFallback: View>: View {
    private let primaryURL: URL?
    private let asyncFallbackURL: (@Sendable () async -> URL?)?
    private let backgroundSample: (@Sendable () async -> HeroBackgroundSample?)?
    private let maxWidth: CGFloat
    private let maxHeight: CGFloat
    private let textFallback: () -> TextFallback

    public init(
        primaryURL: URL?,
        asyncFallbackURL: (@Sendable () async -> URL?)? = nil,
        backgroundSample: (@Sendable () async -> HeroBackgroundSample?)? = nil,
        maxWidth: CGFloat = 620,
        maxHeight: CGFloat = 200,
        @ViewBuilder textFallback: @escaping () -> TextFallback
    ) {
        self.primaryURL = primaryURL
        self.asyncFallbackURL = asyncFallbackURL
        self.backgroundSample = backgroundSample
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.textFallback = textFallback
    }

    public var body: some View {
        #if canImport(UIKit)
        LoadedLogo(
            primaryURL: primaryURL,
            asyncFallbackURL: asyncFallbackURL,
            backgroundSample: backgroundSample,
            maxWidth: maxWidth,
            maxHeight: maxHeight,
            textFallback: textFallback
        )
        #else
        textFallback()
        #endif
    }
}

#if canImport(UIKit)
private struct LoadedLogo<TextFallback: View>: View {
    let primaryURL: URL?
    let asyncFallbackURL: (@Sendable () async -> URL?)?
    let backgroundSample: (@Sendable () async -> HeroBackgroundSample?)?
    let maxWidth: CGFloat
    let maxHeight: CGFloat
    let textFallback: () -> TextFallback

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    @State private var image: ProcessedLogo?
    @State private var resolved = false

    var body: some View {
        Group {
            if let processed = image {
                logo(processed)
                    .transition(.opacity)
            } else if resolved {
                textFallback()
            } else {
                // While loading, hold the title in place so the hero doesn't jump
                // when a logo resolves a beat later.
                textFallback().opacity(0)
            }
        }
        .animation(reduceMotion ? nil : .easeIn(duration: 0.25), value: image != nil)
        .task(id: taskKey) { await resolve() }
    }

    /// Renders the resolved logo. Most logos draw as-is with an adaptive contrast
    /// halo, applied *only* to logos that need it (`needsHalo`): a soft light glow
    /// behind dark logos, a soft dark shadow behind light ones — used only when the
    /// measured logo/background contrast is low, so logos that already stand out
    /// stay clean.
    ///
    /// A *monochrome* logo (a single near-grayscale tone, e.g. an all-black or
    /// all-white wordmark) is instead recoloured to the foreground tone of the
    /// current colour scheme — white in dark mode, black in light mode — so a
    /// black wordmark on a dark hero flips to white and stays legible, matching how
    /// the rest of the UI adapts. Its alpha (the letter shapes) is preserved as a
    /// template mask, so only single-tone logos qualify (guarded in `finalize`),
    /// never multi-colour brand art. It needs no halo: it is recoloured to the
    /// scheme's foreground tone and the hero scrim is the scheme's background tone,
    /// so it is guaranteed to contrast with what sits behind it.
    @ViewBuilder
    private func logo(_ processed: ProcessedLogo) -> some View {
        if processed.isMonochrome {
            let tintLight = colorScheme == .dark   // dark mode → light (white) logo
            Image(uiImage: processed.image)
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: maxWidth, maxHeight: maxHeight, alignment: .leading)
                .foregroundStyle(tintLight ? Color.white : Color.black)
        } else {
            Image(uiImage: processed.image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: maxWidth, maxHeight: maxHeight, alignment: .leading)
                .modifier(LogoLegibilityHalo(isDark: processed.isDark, active: processed.needsHalo))
        }
    }

    /// Re-run resolution whenever the candidate sources change.
    private var taskKey: String {
        "\(primaryURL?.absoluteString ?? "")|\(asyncFallbackURL == nil ? "0" : "1")"
    }

    private func resolve() async {
        resolved = false
        image = nil
        if let primaryURL, let prepared = await Self.load(primaryURL) {
            image = await finalize(prepared)
            resolved = true
            return
        }
        if let asyncFallbackURL, let url = await asyncFallbackURL(), let prepared = await Self.load(url) {
            image = await finalize(prepared)
            resolved = true
            return
        }
        resolved = true
    }

    /// Combines the prepared logo with a colour sample of the background to decide
    /// whether the legibility halo is needed. With no sample available we keep the
    /// halo on, since we can't prove the logo is safe without it.
    ///
    /// A logo is legible when it separates from the artwork behind it by *either*
    /// brightness or colour, so the halo is reserved for the cases where it does
    /// neither: the luminance gap is small **and** the colours are close. That
    /// keeps vibrant wordmarks (e.g. a saturated red logo on near-black) clean,
    /// even though their luminance sits close to the dark backdrop's.
    private func finalize(_ prepared: PreparedLogo) async -> ProcessedLogo {
        let isDark = prepared.luminance < 0.5
        // A logo is "monochrome" when its visible pixels are a single near-grayscale
        // tone at one luminance extreme — an all-black or all-white wordmark. Such a
        // logo can be safely recoloured to the current scheme's foreground tone via
        // its alpha mask. The coverage guard excludes images that never had their
        // background removed (a near-solid rectangle), whose alpha mask would tint
        // the whole box rather than just letter shapes.
        let chroma = max(prepared.red, prepared.green, prepared.blue)
            - min(prepared.red, prepared.green, prepared.blue)
        let isMonochrome = prepared.coverage < 0.85
            && chroma < 0.10
            && (prepared.luminance < 0.22 || prepared.luminance > 0.85)

        var needsHalo = true
        if let bg = await backgroundSample?() {
            let lumaGap = abs(prepared.luminance - bg.luminance)
            let colorGap = Self.perceptualDistance(
                r1: prepared.red, g1: prepared.green, b1: prepared.blue,
                r2: bg.red, g2: bg.green, b2: bg.blue
            )
            needsHalo = lumaGap < Self.haloLuminanceThreshold
                && colorGap < Self.haloColorThreshold
        }
        return ProcessedLogo(
            image: prepared.image,
            isDark: isDark,
            needsHalo: needsHalo,
            isMonochrome: isMonochrome
        )
    }

    /// Logo/background luminance gap (0…1) below which the logo no longer
    /// separates by brightness alone. Tuned for a "clean" lean.
    private static var haloLuminanceThreshold: Double { 0.26 }

    /// Perceptual logo/background colour distance (0…~3, see `perceptualDistance`)
    /// below which the logo no longer separates by colour either. Above it a
    /// vibrant logo reads clearly against the backdrop and needs no halo.
    private static var haloColorThreshold: Double { 0.40 }

    /// Weighted ("redmean") RGB distance — a cheap approximation of perceived
    /// colour difference that tracks the eye far better than raw Euclidean RGB.
    /// Inputs are 0…1 per channel; the result ranges 0 (identical) to ~3
    /// (black↔white).
    private static func perceptualDistance(
        r1: Double, g1: Double, b1: Double,
        r2: Double, g2: Double, b2: Double
    ) -> Double {
        let rMean = (r1 + r2) / 2
        let dr = r1 - r2
        let dg = g1 - g2
        let db = b1 - b2
        return ((2 + rMean) * dr * dr + 4 * dg * dg + (3 - rMean) * db * db).squareRoot()
    }

    private static func load(_ url: URL) async -> PreparedLogo? {
        guard let (data, response) = try? await URLSession.shared.data(from: url) else {
            return nil
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            return nil
        }
        guard let image = UIImage(data: data) else { return nil }
        return image.preparedAsHeroLogo()
    }
}

/// A logo after background removal/trim, carrying the mean luminance *and* mean
/// colour of its visible pixels (plus how much of the frame it covers) so the
/// caller can decide whether a contrast halo is needed and whether the logo is a
/// single-tone wordmark safe to recolour.
struct PreparedLogo {
    let image: UIImage
    let luminance: Double
    let red: Double
    let green: Double
    let blue: Double
    /// Alpha-weighted fraction of the whole frame that is opaque (0…1). Low for a
    /// normal wordmark surrounded by transparency; ~1 for a logo whose background
    /// was never removed (a near-solid rectangle), which must not be recoloured.
    let coverage: Double

    init(
        image: UIImage,
        luminance: Double,
        red: Double = 0,
        green: Double = 0,
        blue: Double = 0,
        coverage: Double = 1.0
    ) {
        self.image = image
        self.luminance = luminance
        self.red = red
        self.green = green
        self.blue = blue
        self.coverage = coverage
    }
}

/// A fully-resolved hero logo ready to render: the processed image, whether it
/// reads as dark (halo colour), whether the halo should be shown at all, and
/// whether it is a single-tone wordmark (recoloured to the scheme's foreground,
/// in which case it needs no halo).
struct ProcessedLogo {
    let image: UIImage
    let isDark: Bool
    let needsHalo: Bool
    let isMonochrome: Bool
}

/// Wraps the logo in a soft, single-tone halo so it separates from the hero
/// regardless of the artwork behind it. Two stacked shadows build a stronger,
/// evenly-spread glow than one. `active == false` is a clean pass-through, so a
/// logo that already contrasts with its background renders with no halo at all.
private struct LogoLegibilityHalo: ViewModifier {
    let isDark: Bool
    let active: Bool

    func body(content: Content) -> some View {
        if !active {
            content
        } else if isDark {
            content
                .shadow(color: .white.opacity(0.6), radius: 5)
                .shadow(color: .white.opacity(0.35), radius: 14)
        } else {
            content
                .shadow(color: .black.opacity(0.55), radius: 5)
                .shadow(color: .black.opacity(0.45), radius: 14)
        }
    }
}

private extension UIImage {
    /// Prepares a raw logo image for the hero: strips a baked-in solid-colour
    /// background when present, trims transparent margins so logos align by their
    /// visible content, and measures the logo's luminance (used to pick and gate
    /// the contrast halo). Returns `nil` when nothing usable remains (no decodable
    /// image, or removal erased essentially everything).
    func preparedAsHeroLogo() -> PreparedLogo? {
        guard let cg = cgImage, cg.width > 0, cg.height > 0 else {
            return PreparedLogo(image: self, luminance: 0.0)
        }
        let width = cg.width
        let height = cg.height
        // Guard against pathologically large logos — the per-pixel passes below
        // are O(width*height); skip the heavy work and use the image as-is.
        if width * height > 8_000_000 {
            return PreparedLogo(image: self, luminance: 0.0)
        }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var data = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        let success = data.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard success else { return PreparedLogo(image: self, luminance: 0.0) }

        Self.removeSolidBackground(&data, width: width, height: height, bytesPerRow: bytesPerRow)

        // Content bounds (trim) + luminance, computed in a single pass over the
        // post-removal alpha so transparent margins and the removed plate are
        // both excluded from the tone measurement.
        var minX = width, minY = height, maxX = -1, maxY = -1
        var lumaSum = 0.0
        var lumaWeight = 0.0
        var rSum = 0.0, gSum = 0.0, bSum = 0.0
        for y in 0..<height {
            let rowStart = y * bytesPerRow
            for x in 0..<width {
                let i = rowStart + x * bytesPerPixel
                let a = data[i + 3]
                if a > 10 {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                    // Premultiplied buffer: un-premultiply so partly-transparent
                    // edge pixels don't read as artificially dark.
                    let af = Double(a) / 255.0
                    let r = Double(data[i]) / 255.0 / af
                    let g = Double(data[i + 1]) / 255.0 / af
                    let b = Double(data[i + 2]) / 255.0 / af
                    let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                    lumaSum += luma * af
                    rSum += r * af
                    gSum += g * af
                    bSum += b * af
                    lumaWeight += af
                }
            }
        }

        let luminance = lumaWeight > 0 ? (lumaSum / lumaWeight) : 0.0
        let meanR = lumaWeight > 0 ? (rSum / lumaWeight) : 0.0
        let meanG = lumaWeight > 0 ? (gSum / lumaWeight) : 0.0
        let meanB = lumaWeight > 0 ? (bSum / lumaWeight) : 0.0

        // If background removal (or a fully transparent source) left essentially
        // nothing visible — e.g. a logo whose colour matched its own plate — the
        // logo is unusable. Return nil so the caller falls through to the next
        // source and ultimately the clean styled title, never a blank or boxed logo.
        guard maxX >= minX, maxY >= minY else { return nil }
        // Alpha-weighted opaque fraction of the trimmed bounding box. ~1 when the
        // logo fills its box (a solid plate that was never removed), low for a
        // wordmark surrounded by — and pierced by — transparency.
        let cropArea = Double((maxX - minX + 1) * (maxY - minY + 1))
        let coverage = cropArea > 0 ? min(1.0, lumaWeight / cropArea) : 1.0
        guard let processedFull = Self.makeImage(from: data, width: width, height: height, bytesPerRow: bytesPerRow) else {
            return nil
        }
        let cropRect = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        guard let cropped = processedFull.cropping(to: cropRect) else {
            return PreparedLogo(image: UIImage(cgImage: processedFull, scale: scale, orientation: imageOrientation), luminance: luminance, red: meanR, green: meanG, blue: meanB, coverage: coverage)
        }
        return PreparedLogo(
            image: UIImage(cgImage: cropped, scale: scale, orientation: imageOrientation),
            luminance: luminance,
            red: meanR, green: meanG, blue: meanB,
            coverage: coverage
        )
    }

    /// Builds a CGImage from a premultiplied-RGBA byte buffer.
    private static func makeImage(from data: [UInt8], width: Int, height: Int, bytesPerRow: Int) -> CGImage? {
        var data = data
        return data.withUnsafeMutableBytes { raw -> CGImage? in
            guard let ctx = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            return ctx.makeImage()
        }
    }

    /// Detects a logo shipped on a solid opaque plate (e.g. a black "title card"
    /// box behind the title) and erases that colour to transparency everywhere.
    ///
    /// The background colour is identified from the border ring; the removal only
    /// runs when that ring is opaque and near-uniform, which is the signature of a
    /// deliberate plate rather than real artwork — a genuinely transparent logo
    /// has a transparent border, so this is a no-op for it. When it does run it is
    /// a *global* soft chroma-key, not a border flood-fill: every pixel near the
    /// background colour is removed, with a graded edge so anti-aliased borders
    /// feather cleanly. Going global is what clears the colour trapped *inside*
    /// enclosed letter shapes (the counters of B, O, D, P, R…), which a
    /// border-connected flood-fill leaves behind as ugly solid blobs. It is safe
    /// because the plate colour and the logo's bright/coloured letters are far
    /// apart in colour space, so the letters survive intact. Operates in place on
    /// a premultiplied RGBA buffer.
    private static func removeSolidBackground(_ data: inout [UInt8], width: Int, height: Int, bytesPerRow: Int) {
        let bpp = 4
        guard width > 2, height > 2 else { return }

        // Sample the border ring to estimate the background colour and confirm it
        // is opaque + uniform enough to be a deliberate plate rather than artwork.
        var rSum = 0, gSum = 0, bSum = 0, aSum = 0, count = 0
        func sample(_ x: Int, _ y: Int) {
            let i = y * bytesPerRow + x * bpp
            rSum += Int(data[i]); gSum += Int(data[i + 1]); bSum += Int(data[i + 2]); aSum += Int(data[i + 3])
            count += 1
        }
        for x in stride(from: 0, to: width, by: max(1, width / 64)) {
            sample(x, 0)
            sample(x, height - 1)
        }
        for y in stride(from: 0, to: height, by: max(1, height / 64)) {
            sample(0, y)
            sample(width - 1, y)
        }
        guard count > 0 else { return }

        let avgA = aSum / count
        // A transparent or semi-transparent border means there is no solid plate.
        guard avgA > 250 else { return }
        let avgAf = Double(avgA) / 255.0
        // Un-premultiply the averaged border colour to its true RGB.
        let bgR = Double(rSum) / Double(count) / avgAf
        let bgG = Double(gSum) / Double(count) / avgAf
        let bgB = Double(bSum) / Double(count) / avgAf

        // Reject non-uniform borders (real artwork) by checking spread against the
        // mean: if any sampled border pixel is far from the average, bail out.
        var maxDev = 0.0
        func dev(_ x: Int, _ y: Int) {
            let i = y * bytesPerRow + x * bpp
            let a = Double(data[i + 3]) / 255.0
            guard a > 0 else { maxDev = .greatestFiniteMagnitude; return }
            let r = Double(data[i]) / 255.0 / a * 255.0
            let g = Double(data[i + 1]) / 255.0 / a * 255.0
            let b = Double(data[i + 2]) / 255.0 / a * 255.0
            let d = max(abs(r - bgR), max(abs(g - bgG), abs(b - bgB)))
            if d > maxDev { maxDev = d }
        }
        for x in stride(from: 0, to: width, by: max(1, width / 64)) {
            dev(x, 0); dev(x, height - 1)
        }
        for y in stride(from: 0, to: height, by: max(1, height / 64)) {
            dev(0, y); dev(width - 1, y)
        }
        // Tolerance for "the border is one flat colour". Loose enough to absorb
        // JPEG noise, tight enough to spare gradient/photographic backgrounds.
        guard maxDev <= 26 else { return }

        // Global soft chroma-key. `innerTol` is the squared colour distance from
        // the plate colour treated as pure background (fully transparent);
        // `outerTol` is where a pixel becomes fully opaque logo. Between them the
        // alpha is graded so anti-aliased edges feather instead of leaving a hard
        // fringe. Applied to every pixel (not just border-connected ones) so the
        // background trapped inside enclosed letters is removed too.
        let innerTol = 45.0 * 45.0
        let outerTol = 120.0 * 120.0
        for y in 0..<height {
            let rowStart = y * bytesPerRow
            for x in 0..<width {
                let i = rowStart + x * bpp
                let oldA = Double(data[i + 3]) / 255.0
                guard oldA > 0 else { continue }
                // Un-premultiply to straight RGB to compare against the plate colour.
                let r = Double(data[i]) / 255.0 / oldA * 255.0
                let g = Double(data[i + 1]) / 255.0 / oldA * 255.0
                let b = Double(data[i + 2]) / 255.0 / oldA * 255.0
                let dr = r - bgR, dg = g - bgG, db = b - bgB
                let distSq = dr * dr + dg * dg + db * db
                if distSq <= innerTol {
                    // Pure background: fully transparent.
                    data[i] = 0; data[i + 1] = 0; data[i + 2] = 0; data[i + 3] = 0
                } else if distSq <= outerTol {
                    // Anti-aliased edge: feather alpha toward 0.
                    let t = (distSq - innerTol) / (outerTol - innerTol)
                    let outA = max(0.0, min(1.0, t)) * oldA
                    // Re-premultiply the original straight RGB by the new alpha.
                    data[i] = UInt8(max(0, min(255, r / 255.0 * outA * 255.0)))
                    data[i + 1] = UInt8(max(0, min(255, g / 255.0 * outA * 255.0)))
                    data[i + 2] = UInt8(max(0, min(255, b / 255.0 * outA * 255.0)))
                    data[i + 3] = UInt8(max(0, min(255, outA * 255.0)))
                }
                // else: logo body, leave untouched.
            }
        }
    }
}

/// Samples the effective colour of the hero artwork behind the logo, so the
/// caller can decide whether the logo needs a contrast halo. Fully keyless and
/// on-device: it just downsamples the same backdrop image and averages the
/// left-of-centre band where the logo sits. Returns `nil` when no candidate URL
/// yields a decodable image (the caller then keeps the halo on, to be safe).
public enum HeroBackgroundSampler {
    /// Mean colour + luminance of `region` (normalized, origin top-left) across
    /// the first decodable URL in `urls`. `region` defaults to the left-of-centre
    /// vertical mid-band, which is where the hero's leading-aligned logo renders.
    public static func sample(
        urls: [URL],
        region: CGRect = CGRect(x: 0.0, y: 0.28, width: 0.5, height: 0.40)
    ) async -> HeroBackgroundSample? {
        for url in urls {
            if let sample = await sampleOne(url, region: region) { return sample }
        }
        return nil
    }

    private static func sampleOne(_ url: URL, region: CGRect) async -> HeroBackgroundSample? {
        guard let (data, response) = try? await URLSession.shared.data(from: url) else { return nil }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { return nil }
        guard let image = UIImage(data: data), let cg = image.cgImage, cg.width > 0, cg.height > 0 else {
            return nil
        }

        // Downsample to a tiny thumbnail; we only need an average, so low-quality
        // scaling is plenty and keeps this cheap even for a 4K backdrop.
        let targetW = 100
        let targetH = max(1, Int((Double(cg.height) / Double(cg.width)) * Double(targetW)))
        let bytesPerRow = targetW * 4
        var buf = [UInt8](repeating: 0, count: targetW * targetH * 4)
        let drawn = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress,
                width: targetW,
                height: targetH,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))
            return true
        }
        guard drawn else { return nil }

        // Buffer row 0 is the top of the image, matching the normalized top-left
        // region origin used elsewhere in this file.
        let x0 = max(0, Int(region.minX * Double(targetW)))
        let x1 = min(targetW, max(x0 + 1, Int(region.maxX * Double(targetW))))
        let y0 = max(0, Int(region.minY * Double(targetH)))
        let y1 = min(targetH, max(y0 + 1, Int(region.maxY * Double(targetH))))

        var rSum = 0.0, gSum = 0.0, bSum = 0.0
        var count = 0
        for y in y0..<y1 {
            let rowStart = y * bytesPerRow
            for x in x0..<x1 {
                let i = rowStart + x * 4
                let a = Double(buf[i + 3]) / 255.0
                guard a > 0 else { continue }
                rSum += Double(buf[i]) / 255.0 / a
                gSum += Double(buf[i + 1]) / 255.0 / a
                bSum += Double(buf[i + 2]) / 255.0 / a
                count += 1
            }
        }
        guard count > 0 else { return nil }
        let n = Double(count)
        let r = rSum / n, g = gSum / n, b = bSum / n
        return HeroBackgroundSample(
            red: r, green: g, blue: b,
            luminance: 0.2126 * r + 0.7152 * g + 0.0722 * b
        )
    }
}
#endif
#endif
