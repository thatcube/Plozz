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
/// raw byte download for that URL is still shared across variants (the cache
/// coalesces the network transfer), so multiple variants cost one fetch and N cheap
/// decodes.
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
    /// Full-bleed detail-hero backdrops and ambient samplers. High fidelity but
    /// bounded below 4K so a single backdrop never retains a multi-megabyte bitmap.
    case heroBackdrop
    /// Small square track thumbnails in album/playlist track lists. A 72pt row
    /// thumbnail at 2x is ~144px; cap at 256 for crispness while keeping the
    /// decoded bitmap tiny, so a long playlist (thousands of rows) can prefetch
    /// upcoming art ahead of scroll without retaining large bitmaps.
    case musicThumbnail

    /// Longest-edge cap (in pixels) applied when decoding, or `nil` to decode at the
    /// source's native size. The cap never *upscales*: a source smaller than the cap
    /// decodes at its own size (ImageIO's thumbnail generator only ever shrinks).
    public var maxPixelSize: Int? {
        switch self {
        case .original: return nil
        case .musicThumbnail: return 256
        case .posterCard: return 960
        case .landscapeCard: return 1_200
        case .heroBackdrop: return 2_000
        }
    }

    /// Composite cache key for `url` under this variant, so one source URL can be
    /// cached at more than one variant at once (e.g. a show's backdrop cached small
    /// for an episode card *and* large for the detail hero) without the two
    /// colliding.
    public func cacheKey(for url: URL) -> String {
        "\(rawValue)|\(url.absoluteString)"
    }
}
