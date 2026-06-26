#if canImport(UIKit)
import UIKit
import SwiftUI

/// Pulls the handful of most *prominent, vibrant* colors out of a piece of
/// artwork so the Now Playing screen can paint an Apple Music–style morphing
/// liquid background tinted to the current album.
///
/// The image is drawn into a tiny RGBA bitmap and every pixel is dropped into a
/// quantized color histogram. Buckets are then scored by how much of the image
/// they cover *and* how vivid they are — muddy near-greys and the near-black /
/// near-white extremes are pushed down so the result reads as colorful rather
/// than washed out. Finally we greedily pick buckets that are far enough apart
/// in RGB space, so the palette has genuine variety instead of five shades of
/// the same hue.
public enum ArtworkColorExtractor {
    /// The ordered (most prominent first) prominent colors of `image`, at most
    /// `maxColors`. Returns an empty array if the image can't be read.
    public static func palette(from image: UIImage, maxColors: Int = 5) -> [Color] {
        rawPalette(from: image, maxColors: maxColors).map {
            Color(red: $0.r, green: $0.g, blue: $0.b)
        }
    }

    struct RGB: Equatable {
        var r: Double
        var g: Double
        var b: Double
    }

    /// Sampling grid. 48×48 ≈ 2.3k pixels — plenty to characterize an album
    /// cover, cheap enough to run synchronously off the main thread.
    private static let sampleSize = 48

    static func rawPalette(from image: UIImage, maxColors: Int) -> [RGB] {
        guard maxColors > 0, let cgImage = image.cgImage else { return [] }

        let size = sampleSize
        let bytesPerRow = size * 4
        var pixels = [UInt8](repeating: 0, count: size * bytesPerRow)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = pixels.withUnsafeMutableBytes({ buffer -> CGContext? in
            CGContext(
                data: buffer.baseAddress,
                width: size,
                height: size,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        }) else { return [] }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))

        struct Bucket {
            var count = 0
            var r = 0.0
            var g = 0.0
            var b = 0.0
        }

        var buckets: [Int: Bucket] = [:]
        buckets.reserveCapacity(512)

        var index = 0
        let total = pixels.count
        while index < total {
            let alpha = pixels[index + 3]
            if alpha > 24 {
                let r = pixels[index]
                let g = pixels[index + 1]
                let b = pixels[index + 2]
                // Quantize to 5 bits/channel (32 levels) so similar colors merge.
                let key = (Int(r) >> 3) << 10 | (Int(g) >> 3) << 5 | (Int(b) >> 3)
                var bucket = buckets[key] ?? Bucket()
                bucket.count += 1
                bucket.r += Double(r) / 255.0
                bucket.g += Double(g) / 255.0
                bucket.b += Double(b) / 255.0
                buckets[key] = bucket
            }
            index += 4
        }

        guard !buckets.isEmpty else { return [] }

        // Average each bucket back to a real color and score it by coverage and
        // vibrancy. Saturation is rewarded; the very dark and very bright
        // extremes (where hue barely registers) are damped.
        let scored: [(color: RGB, score: Double)] = buckets.values.map { bucket in
            let n = Double(bucket.count)
            let color = RGB(r: bucket.r / n, g: bucket.g / n, b: bucket.b / n)
            let maxC = max(color.r, color.g, color.b)
            let minC = min(color.r, color.g, color.b)
            let saturation = maxC <= 0 ? 0 : (maxC - minC) / maxC
            let luminance = 0.299 * color.r + 0.587 * color.g + 0.114 * color.b
            // Bell-ish weight peaking at mid luminance so pure black/white lose out.
            let luminanceWeight = 1.0 - pow(abs(luminance - 0.5) * 2.0, 1.5)
            let vibrancy = 0.35 + saturation * 1.4
            let coverage = pow(n, 0.65)
            let score = coverage * vibrancy * max(luminanceWeight, 0.18)
            return (color, score)
        }
        .sorted { $0.score > $1.score }

        // Greedily accept colors that are sufficiently distinct from those
        // already chosen so the palette spans the artwork rather than clustering.
        var chosen: [RGB] = []
        let minDistance = 0.22
        for candidate in scored {
            if chosen.allSatisfy({ distance($0, candidate.color) >= minDistance }) {
                chosen.append(candidate.color)
                if chosen.count >= maxColors { break }
            }
        }

        // Monochrome / low-variety art may not yield enough distinct colors;
        // backfill from the top-scored buckets so callers always get something.
        if chosen.isEmpty {
            chosen = scored.prefix(maxColors).map(\.color)
        }

        return chosen
    }

    private static func distance(_ a: RGB, _ b: RGB) -> Double {
        let dr = a.r - b.r
        let dg = a.g - b.g
        let db = a.b - b.b
        return (dr * dr + dg * dg + db * db).squareRoot()
    }
}
#endif
