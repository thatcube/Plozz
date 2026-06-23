#if canImport(SwiftUI)
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

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
    private let maxWidth: CGFloat
    private let maxHeight: CGFloat
    private let textFallback: () -> TextFallback

    public init(
        primaryURL: URL?,
        asyncFallbackURL: (@Sendable () async -> URL?)? = nil,
        maxWidth: CGFloat = 620,
        maxHeight: CGFloat = 200,
        @ViewBuilder textFallback: @escaping () -> TextFallback
    ) {
        self.primaryURL = primaryURL
        self.asyncFallbackURL = asyncFallbackURL
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.textFallback = textFallback
    }

    public var body: some View {
        #if canImport(UIKit)
        LoadedLogo(
            primaryURL: primaryURL,
            asyncFallbackURL: asyncFallbackURL,
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
    let maxWidth: CGFloat
    let maxHeight: CGFloat
    let textFallback: () -> TextFallback

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var image: ProcessedLogo?
    @State private var resolved = false

    var body: some View {
        Group {
            if let processed = image {
                Image(uiImage: processed.image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: maxWidth, maxHeight: maxHeight, alignment: .leading)
                    // Adaptive contrast halo so the logo stays legible against any
                    // hero: a soft light glow behind dark logos, a soft dark
                    // shadow behind light ones. The illegible cases are precisely
                    // when the logo's tone matches the background's, so keying the
                    // halo off the logo's own luminance fixes dark-on-dark and
                    // light-on-light without sampling the background.
                    .modifier(LogoLegibilityHalo(isDark: processed.isDark))
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

    /// Re-run resolution whenever the candidate sources change.
    private var taskKey: String {
        "\(primaryURL?.absoluteString ?? "")|\(asyncFallbackURL == nil ? "0" : "1")"
    }

    private func resolve() async {
        resolved = false
        image = nil
        if let primaryURL, let loaded = await Self.load(primaryURL) {
            image = loaded
            resolved = true
            return
        }
        if let asyncFallbackURL, let url = await asyncFallbackURL(), let loaded = await Self.load(url) {
            image = loaded
            resolved = true
            return
        }
        resolved = true
    }

    private static func load(_ url: URL) async -> ProcessedLogo? {
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

/// A decoded hero logo plus the legibility metadata derived from its pixels:
/// `isDark` drives the adaptive contrast halo (light glow vs. dark shadow).
struct ProcessedLogo {
    let image: UIImage
    let isDark: Bool
}

/// Wraps the logo in a soft, single-tone halo so it separates from the hero
/// regardless of the artwork behind it. Two stacked shadows build a stronger,
/// evenly-spread glow than one. Harmless in the already-legible cases (a white
/// glow behind a dark logo on a light hero is barely visible).
private struct LogoLegibilityHalo: ViewModifier {
    let isDark: Bool

    func body(content: Content) -> some View {
        if isDark {
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
    /// visible content, and measures the logo's luminance to pick a contrast halo.
    /// Returns `nil` only when there is no decodable backing image.
    func preparedAsHeroLogo() -> ProcessedLogo? {
        guard let cg = cgImage, cg.width > 0, cg.height > 0 else {
            return ProcessedLogo(image: self, isDark: true)
        }
        let width = cg.width
        let height = cg.height
        // Guard against pathologically large logos — the per-pixel passes below
        // are O(width*height); skip the heavy work and use the image as-is.
        if width * height > 8_000_000 {
            return ProcessedLogo(image: self, isDark: true)
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
        guard success else { return ProcessedLogo(image: self, isDark: true) }

        Self.removeSolidBackground(&data, width: width, height: height, bytesPerRow: bytesPerRow)

        // Content bounds (trim) + luminance, computed in a single pass over the
        // post-removal alpha so transparent margins and the removed plate are
        // both excluded from the tone measurement.
        var minX = width, minY = height, maxX = -1, maxY = -1
        var lumaSum = 0.0
        var lumaWeight = 0.0
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
                    lumaWeight += af
                }
            }
        }

        let isDark = lumaWeight > 0 ? (lumaSum / lumaWeight) < 0.5 : true

        guard maxX >= minX, maxY >= minY,
              let processedFull = Self.makeImage(from: data, width: width, height: height, bytesPerRow: bytesPerRow) else {
            return ProcessedLogo(image: self, isDark: isDark)
        }
        let cropRect = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        guard let cropped = processedFull.cropping(to: cropRect) else {
            return ProcessedLogo(image: UIImage(cgImage: processedFull, scale: scale, orientation: imageOrientation), isDark: isDark)
        }
        return ProcessedLogo(
            image: UIImage(cgImage: cropped, scale: scale, orientation: imageOrientation),
            isDark: isDark
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

    /// Detects a logo shipped on a solid opaque plate (e.g. a black box behind
    /// the title) and erases it to transparency. The background is identified
    /// from the border ring; if that ring is opaque and near-uniform, the
    /// connected region of that colour is flood-filled from the edges to alpha 0,
    /// with a graded edge so anti-aliased logo borders feather cleanly instead of
    /// leaving a hard fringe. A genuinely transparent logo has a transparent
    /// border, so this is a no-op for it. Operates in place on a premultiplied
    /// RGBA buffer.
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

        // Flood fill the connected background from every border pixel. `innerTol`
        // is the squared colour distance treated as pure background (alpha 0 and
        // keep spreading); between inner and `outerTol` the pixel is an
        // anti-aliased edge — feather its alpha and stop spreading there.
        let innerTol = 34.0 * 34.0
        let outerTol = 70.0 * 70.0
        var visited = [Bool](repeating: false, count: width * height)
        var stack = [Int]()
        stack.reserveCapacity(1024)

        func colorDistanceSq(_ i: Int) -> (Double, Double) {
            // returns (distanceSq, alphaFraction)
            let a = Double(data[i + 3]) / 255.0
            guard a > 0 else { return (0, 0) }
            let r = Double(data[i]) / 255.0 / a * 255.0
            let g = Double(data[i + 1]) / 255.0 / a * 255.0
            let b = Double(data[i + 2]) / 255.0 / a * 255.0
            let dr = r - bgR, dg = g - bgG, db = b - bgB
            return (dr * dr + dg * dg + db * db, a)
        }

        func enqueueBorder(_ x: Int, _ y: Int) {
            let p = y * width + x
            if !visited[p] { visited[p] = true; stack.append(p) }
        }
        for x in 0..<width { enqueueBorder(x, 0); enqueueBorder(x, height - 1) }
        for y in 0..<height { enqueueBorder(0, y); enqueueBorder(width - 1, y) }

        while let p = stack.popLast() {
            let x = p % width
            let y = p / width
            let i = y * bytesPerRow + x * bpp
            let (distSq, _) = colorDistanceSq(i)
            if distSq <= innerTol {
                // Pure background: fully transparent, keep flooding neighbours.
                data[i] = 0; data[i + 1] = 0; data[i + 2] = 0; data[i + 3] = 0
            } else if distSq <= outerTol {
                // Anti-aliased edge: feather alpha toward 0, but stop here so we
                // don't eat into the logo body.
                let t = (distSq - innerTol) / (outerTol - innerTol)
                let newAf = max(0.0, min(1.0, t))
                let oldA = Double(data[i + 3]) / 255.0
                guard oldA > 0 else { continue }
                // Convert to straight RGB, reapply the feathered alpha premultiplied.
                let r = Double(data[i]) / 255.0 / oldA
                let g = Double(data[i + 1]) / 255.0 / oldA
                let b = Double(data[i + 2]) / 255.0 / oldA
                let outA = newAf * oldA
                data[i] = UInt8(max(0, min(255, r * outA * 255)))
                data[i + 1] = UInt8(max(0, min(255, g * outA * 255)))
                data[i + 2] = UInt8(max(0, min(255, b * outA * 255)))
                data[i + 3] = UInt8(max(0, min(255, outA * 255)))
                continue
            } else {
                // Logo body: leave untouched and stop.
                continue
            }
            if x > 0 { let n = p - 1; if !visited[n] { visited[n] = true; stack.append(n) } }
            if x < width - 1 { let n = p + 1; if !visited[n] { visited[n] = true; stack.append(n) } }
            if y > 0 { let n = p - width; if !visited[n] { visited[n] = true; stack.append(n) } }
            if y < height - 1 { let n = p + width; if !visited[n] { visited[n] = true; stack.append(n) } }
        }
    }
}
#endif
#endif
