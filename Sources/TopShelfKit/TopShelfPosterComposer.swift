import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// Renders Continue-Watching poster artwork with the in-app progress bar
/// **composited into the image**, then caches it in the shared App Group
/// container so the Top Shelf extension can display a poster (2:3) card that
/// still shows a resume bar.
///
/// Why burn it in: tvOS only draws the native `TVTopShelfSectionedItem`
/// `playbackProgress` bar on `.hdtv` (landscape) cards — never on `.poster`
/// cards. A Top Shelf card only lets an app supply an image + title + actions,
/// so the *only* pixels we control on a poster are the artwork itself. Painting
/// the bar into the poster (exactly how apps like Plex do it) is the only way to
/// get a poster card with a progress bar.
///
/// The bar's geometry and colours mirror `PosterCardView.progressBar` at base
/// density (a 12pt bar on a 280pt-wide poster, #00A4DC fill, white-0.22 track,
/// a black-0.6 bottom scrim and a black-0.35 fill shadow), expressed as
/// fractions of the image width so the burned-in bar stays visually identical to
/// the in-app one at any resolution.
public enum TopShelfPosterComposer {
    /// In-app bar proportions, taken from `PosterCardView` / `PlozzTheme` base
    /// metrics (poster width 280, bar height 12, inset 22, scrim = height*8.5,
    /// fill shadow blur = height*0.25). Kept as width fractions so the composited
    /// bar matches the in-app bar regardless of the source image's pixel size.
    private enum Bar {
        static let heightFraction: CGFloat = 12.0 / 280.0
        static let insetFraction: CGFloat = 22.0 / 280.0
        static let scrimFraction: CGFloat = (12.0 * 8.5) / 280.0
        static let shadowBlurFraction: CGFloat = (12.0 * 0.25) / 280.0
        // #00A4DC — ThemePalette.brandBlue.
        static let fillRed: CGFloat = 0.0
        static let fillGreen: CGFloat = 0.643
        static let fillBlue: CGFloat = 0.863
    }

    /// Builds (or reuses a cached) composited poster for one in-progress item and
    /// returns a **local file URL** inside the shared App Group container, or
    /// `nil` if compositing isn't possible (no UIKit, fetch/decode failure). On
    /// `nil`, callers should fall back to the plain remote poster URL.
    ///
    /// - Parameters:
    ///   - id: The item's stable id (used for the cache filename + deep link).
    ///   - posterURL: Remote poster artwork to draw the bar onto.
    ///   - progress: Fraction watched (0…1). Only the `(0.01, 0.99)` band draws a
    ///     bar, matching the in-app `showsProgressBar` rule.
    public static func compositedPosterURL(
        id: String,
        posterURL: URL,
        progress: Double
    ) async -> URL? {
        #if canImport(UIKit)
        guard progress > 0.01, progress < 0.99 else { return nil }
        guard let directory = TopShelfStore.artworkDirectoryURL else { return nil }

        let bucket = Int((progress * 100).rounded())
        // Fold the source art URL into the cache key so that when an item's chosen
        // poster changes (e.g. an episode gains a real series poster instead of a
        // stretched backdrop) the composite is regenerated rather than served
        // stale. Stale files are then pruned by `TopShelfStore.pruneArtwork`.
        let artKey = String(fnv1a(posterURL.absoluteString), radix: 16)
        let fileName = "\(sanitize(id))_\(bucket)_\(artKey).png"
        let destination = directory.appendingPathComponent(fileName)

        // Reuse an identical prior render (same item + same rounded percentage).
        if FileManager.default.fileExists(atPath: destination.path) {
            return destination
        }

        guard let base = await loadImage(from: posterURL) else { return nil }
        guard let data = render(base: base, progress: CGFloat(progress)) else { return nil }

        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            try data.write(to: destination, options: .atomic)
            return destination
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    /// Builds (or reuses a cached) neutral placeholder poster for an item that has
    /// no vertical artwork at all, returning a local file URL in the shared App
    /// Group container (or `nil` when UIKit is unavailable / the write fails). The
    /// resume bar is burned in when `progress` is in the `(0.01, 0.99)` band;
    /// otherwise a plain title-card placeholder is produced.
    public static func placeholderPosterURL(
        id: String,
        title: String,
        progress: Double?
    ) -> URL? {
        #if canImport(UIKit)
        guard let directory = TopShelfStore.artworkDirectoryURL else { return nil }

        let barProgress: CGFloat? = progress.flatMap {
            ($0 > 0.01 && $0 < 0.99) ? CGFloat($0) : nil
        }
        let bucketPart = barProgress.map { String(Int(($0 * 100).rounded())) } ?? "none"
        // Key on the title too so a renamed item regenerates its placeholder.
        let titleKey = String(fnv1a("ph|" + title), radix: 16)
        let fileName = "\(sanitize(id))_ph_\(bucketPart)_\(titleKey).png"
        let destination = directory.appendingPathComponent(fileName)

        if FileManager.default.fileExists(atPath: destination.path) {
            return destination
        }

        guard let data = renderPlaceholder(title: title, progress: barProgress) else { return nil }

        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            try data.write(to: destination, options: .atomic)
            return destination
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    #if canImport(UIKit)
    private static func loadImage(from url: URL) async -> UIImage? {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return UIImage(data: data)
        } catch {
            return nil
        }
    }

    /// Draws `base` with the progress bar overlaid, returning PNG data. The bar's
    /// scrim → track → fill layering and every colour/scale factor mirror
    /// `PosterCardView.progressBar` so the shelf and Home rows read identically.
    private static func render(base: UIImage, progress: CGFloat) -> Data? {
        let size = base.size
        guard size.width > 0, size.height > 0 else { return nil }

        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)

        return renderer.pngData { context in
            base.draw(in: CGRect(origin: .zero, size: size))
            drawProgressBar(in: context.cgContext, size: size, progress: progress)
        }
    }

    /// Renders a neutral 2:3 placeholder poster for an item with no vertical
    /// artwork, mirroring the in-app `PosterCardView.neutralPlaceholder`: a faint
    /// fill, a centred `play.rectangle` glyph and the title. The resume bar is
    /// burned in when `progress` is in the `(0.01, 0.99)` band.
    private static func renderPlaceholder(title: String, progress: CGFloat?) -> Data? {
        let size = CGSize(width: 400, height: 600)
        let width = size.width
        let height = size.height

        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)

        return renderer.pngData { context in
            let cg = context.cgContext

            // Neutral dark card fill (the shelf sits on a dark background, so the
            // card needs an opaque body rather than the in-app translucent tint).
            UIColor(white: 0.14, alpha: 1).setFill()
            cg.fill(CGRect(origin: .zero, size: size))

            // Centred play glyph, mirroring the in-app placeholder symbol.
            let glyphColor = UIColor(white: 1, alpha: 0.55)
            let symbolConfig = UIImage.SymbolConfiguration(pointSize: width * 0.16, weight: .regular)
            if let symbol = UIImage(systemName: "play.rectangle", withConfiguration: symbolConfig)?
                .withTintColor(glyphColor, renderingMode: .alwaysOriginal) {
                let glyphSize = symbol.size
                symbol.draw(in: CGRect(
                    x: (width - glyphSize.width) / 2,
                    y: height * 0.34 - glyphSize.height / 2,
                    width: glyphSize.width,
                    height: glyphSize.height
                ))
            }

            // Title, centred under the glyph, wrapping to at most two lines.
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byTruncatingTail
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: width * 0.075, weight: .semibold),
                .foregroundColor: UIColor(white: 1, alpha: 0.9),
                .paragraphStyle: paragraph,
            ]
            let textRect = CGRect(x: width * 0.1, y: height * 0.44, width: width * 0.8, height: height * 0.26)
            (title as NSString).draw(
                with: textRect,
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: attributes,
                context: nil
            )

            if let progress {
                drawProgressBar(in: cg, size: size, progress: progress)
            }
        }
    }

    /// Draws the resume bar (scrim → track → fill) into `cg` for a card of `size`.
    /// Shared by the real-poster and placeholder renderers so the bar is identical
    /// everywhere and matches the in-app `PosterCardView.progressBar`.
    private static func drawProgressBar(in cg: CGContext, size: CGSize, progress: CGFloat) {
        let width = size.width
        let height = size.height
        let barHeight = width * Bar.heightFraction
        let inset = width * Bar.insetFraction
        let scrimHeight = width * Bar.scrimFraction
        let shadowBlur = width * Bar.shadowBlurFraction
        let trackWidth = max(0, width - inset * 2)
        let barTop = height - inset - barHeight
        let fillWidth = min(trackWidth, max(barHeight, trackWidth * progress))

        // Scrim: clear (top) → black 0.6 (bottom), full width, pinned to the
        // bottom edge so the bar pops off bright artwork (matches in-app).
        let scrimRect = CGRect(x: 0, y: height - scrimHeight, width: width, height: scrimHeight)
        cg.saveGState()
        cg.clip(to: scrimRect)
        let space = CGColorSpaceCreateDeviceRGB()
        let scrimColors = [
            UIColor.black.withAlphaComponent(0).cgColor,
            UIColor.black.withAlphaComponent(0.6).cgColor,
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: space, colors: scrimColors, locations: [0, 1]) {
            cg.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: scrimRect.minY),
                end: CGPoint(x: 0, y: scrimRect.maxY),
                options: []
            )
        }
        cg.restoreGState()

        let radius = barHeight / 2

        // Track: translucent white capsule.
        let trackRect = CGRect(x: inset, y: barTop, width: trackWidth, height: barHeight)
        UIColor.white.withAlphaComponent(0.22).setFill()
        UIBezierPath(roundedRect: trackRect, cornerRadius: radius).fill()

        // Fill: brand-blue capsule with a soft drop shadow.
        let fillRect = CGRect(x: inset, y: barTop, width: fillWidth, height: barHeight)
        cg.saveGState()
        cg.setShadow(
            offset: .zero,
            blur: shadowBlur,
            color: UIColor.black.withAlphaComponent(0.35).cgColor
        )
        UIColor(red: Bar.fillRed, green: Bar.fillGreen, blue: Bar.fillBlue, alpha: 1).setFill()
        UIBezierPath(roundedRect: fillRect, cornerRadius: radius).fill()
        cg.restoreGState()
    }
    #endif

    /// Turns an item id into a filesystem-safe filename stem (ids can be GUIDs or
    /// contain provider-specific separators).
    private static func sanitize(_ id: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let mapped = id.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(mapped)
    }

    /// A small, deterministic FNV-1a hash (stable across launches, unlike
    /// `Hasher`) used to key the composite cache on its source art URL.
    private static func fnv1a(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x1000_0000_01b3
        }
        return hash
    }
}
