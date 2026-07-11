import Foundation

/// The on-screen role an artwork load is destined for, which bounds how large the
/// decoded image needs to be.
///
/// Poster/landscape **cards** are tiny relative to what the art servers hand back —
/// a landscape rail card is ~480pt wide yet its backdrop/still source is 1280px, and
/// TMDb stills are `w1280`. Decoding and retaining those at full source size wastes
/// CPU and (more importantly on the low-power Apple TV HD) memory, so a poster wall
/// evicts itself and re-decodes during a fast scroll — the exact gray-flash the
/// decoded-image cache exists to prevent. Each card variant caps the decoded longest
/// edge so cards stay crisp but cheap; `.heroBackdrop` keeps full-bleed detail-hero /
/// now-playing art at high fidelity (but still bounded below 4K); `.original` decodes
/// at the source's native size for anything that genuinely needs it.
///
/// The same source URL can be resident at several variants at once without collision
/// (an episode card's small backdrop and the detail hero's large one), because the
/// cache key is composed from the variant *and* the URL — see `cacheKey(for:)`. The
/// The source URL remains the cache identity, while ``requestURL(for:)`` asks known
/// image servers for no more pixels than this variant can display. Variants that
/// resolve to the same request URL still share `URLCache` bytes; a small progressive
/// preview deliberately gets its own much smaller response so it can paint sooner.
///
/// This type is Foundation-only (no UIKit/SwiftUI) so the size policy and cache-key
/// composition stay unit-testable off-device.
public enum ArtworkImageVariant: String, Sendable, CaseIterable {
    /// Native source size — no downsampling. Used when a consumer genuinely needs the
    /// full-resolution image.
    case original
    /// Vertical poster wall cards. ~420pt at 2x plus focus-lift headroom.
    case posterCard
    /// Wide landscape / episode-still cards. ~480pt at 2x plus focus-lift headroom.
    case landscapeCard
    /// Lightweight full-bleed hero preview. Small enough to retain one for every
    /// configured hero slide, used only as an immediate progressive frame while
    /// the high-fidelity hero decode finishes.
    case heroPreview
    /// Full-bleed detail-hero backdrops and ambient samplers. High fidelity but
    /// bounded below 4K so a single backdrop never retains a multi-megabyte bitmap.
    case heroBackdrop
    /// Small square track thumbnails in album/playlist track lists. A 72pt row
    /// thumbnail at 2x is ~144px; cap at 256 for crispness while keeping the
    /// decoded bitmap tiny, so a long playlist (thousands of rows) can prefetch
    /// upcoming art ahead of scroll without retaining large bitmaps.
    case musicThumbnail
    /// Circular cast/crew headshots in the detail-page people row. Shown at
    /// roughly a 150–200pt circle, so ~400px at 2x is plenty; a cast of 30–50
    /// people would otherwise decode 30–50 full-size (multi-MB) profile images —
    /// hundreds of MB — for tiny circles. Capped small keeps a full cast cheap.
    case personHeadshot

    /// Longest-edge cap (in pixels) applied when decoding, or `nil` to decode at the
    /// source's native size. The cap never *upscales*: a source smaller than the cap
    /// decodes at its own size (ImageIO's thumbnail generator only ever shrinks).
    public var maxPixelSize: Int? {
        switch self {
        case .original: return nil
        case .musicThumbnail: return 256
        case .personHeadshot: return 400
        case .posterCard: return 960
        case .landscapeCard: return 1_200
        case .heroPreview: return 768
        case .heroBackdrop: return 2_000
        }
    }

    /// Returns a transfer URL capped to this variant's decode size when the source
    /// is a known resizable image endpoint. The original URL remains the decoded
    /// cache key, so callers never need to know that the byte request was right-sized.
    ///
    /// Never raises an existing size limit: a 1280px TMDb or Jellyfin image remains
    /// 1280px for a 2000px hero rather than being upscaled by the server.
    public func requestURL(for sourceURL: URL) -> URL {
        guard let maxPixelSize else { return sourceURL }
        if let jellyfin = resizedJellyfinURL(sourceURL, maxPixelSize: maxPixelSize) {
            return jellyfin
        }
        if let plex = resizedPlexURL(sourceURL, maxPixelSize: maxPixelSize) {
            return plex
        }
        if let tmdb = resizedTMDbURL(sourceURL, maxPixelSize: maxPixelSize) {
            return tmdb
        }
        return sourceURL
    }

    /// Composite cache key for `url` under this variant, so one source URL can be
    /// cached at more than one variant at once (e.g. a show's backdrop cached small
    /// for an episode card *and* large for the detail hero) without the two
    /// colliding.
    public func cacheKey(for url: URL) -> String {
        "\(rawValue)|\(url.absoluteString)"
    }

    private func resizedJellyfinURL(_ url: URL, maxPixelSize: Int) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.path.localizedCaseInsensitiveContains("/images/"),
              var queryItems = components.queryItems,
              let index = queryItems.firstIndex(where: { $0.name.lowercased() == "maxwidth" }),
              let value = queryItems[index].value,
              let currentWidth = Int(value),
              currentWidth > maxPixelSize
        else {
            return nil
        }
        queryItems[index].value = String(maxPixelSize)
        components.queryItems = queryItems
        return components.url
    }

    private func resizedPlexURL(_ url: URL, maxPixelSize: Int) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.path.hasSuffix("/photo/:/transcode"),
              var queryItems = components.percentEncodedQueryItems,
              let widthIndex = queryItems.firstIndex(where: { $0.name == "width" }),
              let widthValue = queryItems[widthIndex].value,
              let currentWidth = Int(widthValue),
              currentWidth > maxPixelSize
        else {
            return nil
        }

        if let heightIndex = queryItems.firstIndex(where: { $0.name == "height" }),
           let heightValue = queryItems[heightIndex].value,
           let currentHeight = Int(heightValue),
           currentHeight > 0 {
            let ratio = Double(currentHeight) / Double(currentWidth)
            queryItems[heightIndex].value = String(max(1, Int((Double(maxPixelSize) * ratio).rounded())))
        }
        queryItems[widthIndex].value = String(maxPixelSize)
        components.percentEncodedQueryItems = queryItems
        return components.url
    }

    private func resizedTMDbURL(_ url: URL, maxPixelSize: Int) -> URL? {
        guard url.host?.lowercased() == "image.tmdb.org" else { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        guard var pathParts = components?.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init),
              pathParts.count >= 4,
              pathParts[0] == "t",
              pathParts[1] == "p"
        else {
            return nil
        }

        let currentSize = pathParts[2]
        let currentWidth = currentSize.first == "w" ? Int(currentSize.dropFirst()) : nil
        let widths = [92, 154, 185, 342, 500, 780, 1_280]
        guard let requestedWidth = widths.first(where: { $0 >= maxPixelSize }),
              currentSize == "original" || (currentWidth.map { $0 > requestedWidth } ?? false)
        else {
            return nil
        }

        pathParts[2] = "w\(requestedWidth)"
        components?.path = "/" + pathParts.joined(separator: "/")
        return components?.url
    }
}
