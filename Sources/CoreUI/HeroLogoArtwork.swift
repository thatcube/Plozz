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

    @State private var image: UIImage?
    @State private var resolved = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: maxWidth, maxHeight: maxHeight, alignment: .leading)
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

    private static func load(_ url: URL) async -> UIImage? {
        guard let (data, response) = try? await URLSession.shared.data(from: url) else {
            return nil
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            return nil
        }
        guard let image = UIImage(data: data) else { return nil }
        // Logos ship with wildly inconsistent baked-in transparent margins, which
        // is why some appear indented while others hug the edge. Trim the
        // transparent border so every logo aligns by its visible content.
        return image.trimmingTransparentPixels() ?? image
    }
}

private extension UIImage {
    /// Returns a copy cropped to the bounding box of its non-transparent pixels,
    /// removing baked-in transparent padding so logos align consistently. `nil`
    /// when there is no backing image or it is entirely transparent.
    func trimmingTransparentPixels(alphaThreshold: UInt8 = 10) -> UIImage? {
        guard let cg = cgImage, cg.width > 0, cg.height > 0 else { return nil }
        let width = cg.width
        let height = cg.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var data = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        guard let ctx = CGContext(
            data: &data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))

        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let rowStart = y * bytesPerRow
            for x in 0..<width {
                if data[rowStart + x * bytesPerPixel + 3] > alphaThreshold {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let cropRect = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        guard let cropped = cg.cropping(to: cropRect) else { return nil }
        return UIImage(cgImage: cropped, scale: scale, orientation: imageOrientation)
    }
}
#endif
#endif
