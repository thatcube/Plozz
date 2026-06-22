import Foundation

/// A small, provider-agnostic capability badge shown on a detail hero, e.g.
/// `4K`, `Dolby Vision`, `Dolby Atmos`, `5.1`, or a content rating like `TV-14`.
///
/// Derived from `MediaItem`/`MediaSourceMetadata` so the decision of *what* to
/// show is one pure, testable place; the UI layer only decides *how* to paint
/// each `Style`.
public struct MediaBadge: Hashable, Sendable, Identifiable {
    /// How prominently a badge should read.
    public enum Style: String, Sendable, Hashable {
        /// A hairline-outlined pill (content ratings, resolution, plain HDR).
        case outlined
        /// A filled/tinted pill that draws the eye (premium formats such as
        /// Dolby Vision, HDR10+, Dolby Atmos, DTS:X).
        case prominent
    }

    public var label: String
    public var style: Style

    public var id: String { "\(style.rawValue):\(label)" }

    public init(_ label: String, style: Style = .outlined) {
        self.label = label
        self.style = style
    }
}

// MARK: - Technical badges from stream metadata

public extension MediaSourceMetadata {
    /// A single resolution-tier badge (`4K`, `1080p`, `720p`, `SD`) from the
    /// video stream's pixel dimensions, or `nil` when no dimensions are known.
    var resolutionBadge: MediaBadge? {
        guard let video else { return nil }
        // Use the vertical resolution where known; otherwise infer it from width
        // assuming roughly 16:9 so unusual aspect ratios still classify sensibly.
        let lines: Int?
        if let height = video.height, height > 0 {
            lines = height
        } else if let width = video.width, width > 0 {
            lines = width * 9 / 16
        } else {
            lines = nil
        }
        guard let lines else { return nil }
        let label: String
        switch lines {
        case 2000...: label = "4K"
        case 1400..<2000: label = "1440p"
        case 1000..<1400: label = "1080p"
        case 700..<1000: label = "720p"
        default: label = "SD"
        }
        return MediaBadge(label, style: .outlined)
    }

    /// At most one dynamic-range badge describing the HDR/Dolby Vision signal:
    /// `Dolby Vision`, `HDR10+`, `HDR10`, `HLG`, or a generic `HDR`. Empty for
    /// SDR content. Premium ranges read as `.prominent`.
    var dynamicRangeBadges: [MediaBadge] {
        guard let video else { return [] }
        let rangeType = (video.videoRangeType ?? "").uppercased()
        let range = (video.videoRange ?? "").uppercased()

        if rangeType.hasPrefix("DOVI") || range == "DOVI" {
            return [MediaBadge("Dolby Vision", style: .prominent)]
        }
        if rangeType.contains("HDR10PLUS") || rangeType.contains("HDR10+") {
            return [MediaBadge("HDR10+", style: .prominent)]
        }
        if rangeType.hasPrefix("HDR10") {
            return [MediaBadge("HDR10", style: .outlined)]
        }
        if rangeType == "HLG" || rangeType.hasPrefix("HLG") {
            return [MediaBadge("HLG", style: .outlined)]
        }
        if rangeType.hasPrefix("HDR") || range == "HDR" {
            return [MediaBadge("HDR", style: .outlined)]
        }
        return []
    }

    /// Audio capability badges: a headline format badge (Dolby Atmos, DTS:X,
    /// Dolby TrueHD, DTS-HD, Dolby Digital+/Dolby Digital) and, when the format
    /// isn't already object-based surround, a channel-layout badge (`5.1`/`7.1`).
    var audioBadges: [MediaBadge] {
        guard let audio else { return [] }
        var badges: [MediaBadge] = []
        let profile = (audio.profile ?? "").lowercased()
        let codec = (audio.codec ?? "").lowercased()

        // Object-based / lossless headline formats imply surround on their own,
        // so they suppress the separate channel badge below.
        var formatImpliesSurround = false
        if profile.contains("atmos") {
            badges.append(MediaBadge("Dolby Atmos", style: .prominent))
            formatImpliesSurround = true
        } else if profile.contains("dts:x") || profile.contains("dtsx") || profile.contains("dts x") {
            badges.append(MediaBadge("DTS:X", style: .prominent))
            formatImpliesSurround = true
        } else if codec == "truehd" {
            badges.append(MediaBadge("Dolby TrueHD", style: .prominent))
            formatImpliesSurround = true
        } else if codec == "dts" && (profile.contains("hd") || profile.contains("ma")) {
            badges.append(MediaBadge("DTS-HD", style: .outlined))
        } else if codec == "eac3" {
            badges.append(MediaBadge("Dolby Digital+", style: .outlined))
        } else if codec == "ac3" {
            badges.append(MediaBadge("Dolby Digital", style: .outlined))
        }

        if !formatImpliesSurround, let channels = Self.surroundLabel(
            channelLayout: audio.channelLayout,
            channels: audio.channels
        ) {
            badges.append(MediaBadge(channels, style: .outlined))
        }
        return badges
    }

    /// The full ordered technical badge set: resolution, dynamic range, audio.
    var technicalBadges: [MediaBadge] {
        var badges: [MediaBadge] = []
        if let resolutionBadge { badges.append(resolutionBadge) }
        badges.append(contentsOf: dynamicRangeBadges)
        badges.append(contentsOf: audioBadges)
        return badges
    }

    /// A surround-channel label (`7.1`, `5.1`) from a layout string or channel
    /// count. Returns `nil` for stereo/mono (not a highlight) or unknown.
    private static func surroundLabel(channelLayout: String?, channels: Int?) -> String? {
        if let layout = channelLayout?.lowercased() {
            if layout.contains("7.1") { return "7.1" }
            if layout.contains("5.1") { return "5.1" }
        }
        switch channels {
        case .some(let c) where c >= 8: return "7.1"
        case .some(let c) where c >= 6: return "5.1"
        default: return nil
        }
    }
}

// MARK: - Item-level badges & metadata line

public extension MediaItem {
    /// The content-rating badge (e.g. `TV-14`, `PG-13`) when the provider reports
    /// a non-empty certificate. Always `.outlined`.
    var ratingBadge: MediaBadge? {
        guard let officialRating = officialRating?.trimmingCharacters(in: .whitespacesAndNewlines),
              !officialRating.isEmpty else { return nil }
        return MediaBadge(officialRating, style: .outlined)
    }

    /// Technical (resolution/HDR/audio) badges, gated to playable single-file
    /// kinds — a series/season/collection has no single media file, so these are
    /// only meaningful for movies, episodes and standalone videos.
    var technicalBadges: [MediaBadge] {
        switch kind {
        case .movie, .episode, .video:
            return mediaInfo?.technicalBadges ?? []
        default:
            return []
        }
    }

    /// The dotted metadata line components for the detail hero, in order:
    /// production year, formatted runtime, then up to `maxGenres` genres. The UI
    /// joins these with a `·` separator. Empty entries are omitted.
    func metadataComponents(maxGenres: Int = 3) -> [String] {
        var parts: [String] = []
        if let productionYear { parts.append(String(productionYear)) }
        if let runtimeText = runtime?.runtimeBadgeText { parts.append(runtimeText) }
        parts.append(contentsOf: genres.prefix(maxGenres))
        return parts
    }
}

public extension TimeInterval {
    /// A compact human runtime label, e.g. `2h 28m`, `47m`, or `1h`. Returns
    /// `nil` for non-positive durations (unknown runtime).
    var runtimeBadgeText: String? {
        guard self > 0 else { return nil }
        let totalMinutes = Int((self / 60).rounded())
        guard totalMinutes > 0 else { return nil }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        switch (hours, minutes) {
        case (0, let m): return "\(m)m"
        case (let h, 0): return "\(h)h"
        case (let h, let m): return "\(h)h \(m)m"
        }
    }
}
