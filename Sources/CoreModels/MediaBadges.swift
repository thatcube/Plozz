import Foundation

/// A small, provider-agnostic capability badge shown on a detail hero, e.g.
/// `4K`, `Dolby Vision`, `Dolby Atmos`, `5.1`, or a content rating like `TV-14`.
///
/// Derived from `MediaItem`/`MediaSourceMetadata` so the decision of *what* to
/// show is one pure, testable place; the UI layer only decides *how* to paint
/// each `Style`.
public struct MediaBadge: Hashable, Sendable, Identifiable {
    /// How a badge should be painted, mirroring the three visual treatments
    /// Apple TV uses in its detail hero.
    public enum Style: String, Sendable, Hashable {
        /// An outlined pill with a transparent fill — content ratings such as
        /// `TV-14` or `PG-13`.
        case rating
        /// A solid, faintly-filled gray pill — technical specs such as `4K`,
        /// `HDR`, `HDR10`, `5.1`, `DTS:X`.
        case spec
        /// A highly visible solid pill (e.g. solid white with dark text) for
        /// the primary resolution badge.
        case prominent
        /// A Dolby badge rendered as the double-D logo with a stacked wordmark
        /// (`Dolby` over the format, e.g. Dolby Vision / Atmos / Digital+). No
        /// pill.
        case dolby
    }

    public var label: String
    public var style: Style

    public var id: String { "\(style.rawValue):\(label)" }

    public init(_ label: String, style: Style = .spec) {
        self.label = label
        self.style = style
    }

    /// For `.dolby` badges, the format word(s) after the leading "Dolby " (e.g.
    /// `Vision`, `Atmos`, `Digital+`) — the logo conveys the "Dolby". For any
    /// other style this is just the full label.
    public var dolbyFormatWord: String {
        guard style == .dolby else { return label }
        let prefix = "Dolby "
        if label.hasPrefix(prefix) {
            return String(label.dropFirst(prefix.count))
        }
        return label
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
        return MediaBadge(label, style: .prominent)
    }

    /// At most one dynamic-range badge describing the HDR/Dolby Vision signal:
    /// `Dolby Vision`, `HDR10+`, `HDR10`, `HLG`, or a generic `HDR`. Empty for
    /// SDR content. Premium ranges read as `.prominent`.
    var dynamicRangeBadges: [MediaBadge] {
        guard let video else { return [] }
        let rangeType = (video.videoRangeType ?? "").uppercased()
        let range = (video.videoRange ?? "").uppercased()

        if rangeType.hasPrefix("DOVI") || range == "DOVI" {
            return [MediaBadge("Dolby Vision", style: .dolby)]
        }
        if rangeType.contains("HDR10PLUS") || rangeType.contains("HDR10+") {
            return [MediaBadge("HDR10+", style: .spec)]
        }
        if rangeType.hasPrefix("HDR10") {
            return [MediaBadge("HDR10", style: .spec)]
        }
        if rangeType == "HLG" || rangeType.hasPrefix("HLG") {
            return [MediaBadge("HLG", style: .spec)]
        }
        if rangeType.hasPrefix("HDR") || range == "HDR" {
            return [MediaBadge("HDR", style: .spec)]
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
            badges.append(MediaBadge("Dolby Atmos", style: .dolby))
            formatImpliesSurround = true
        } else if profile.contains("dts:x") || profile.contains("dtsx") || profile.contains("dts x") {
            badges.append(MediaBadge("DTS:X", style: .spec))
            formatImpliesSurround = true
        } else if codec == "truehd" {
            badges.append(MediaBadge("Dolby TrueHD", style: .dolby))
            formatImpliesSurround = true
        } else if codec == "dts" && (profile.contains("hd") || profile.contains("ma")) {
            badges.append(MediaBadge("DTS-HD", style: .spec))
        } else if codec == "eac3" {
            badges.append(MediaBadge("Dolby Digital+", style: .dolby))
        } else if codec == "ac3" {
            badges.append(MediaBadge("Dolby Digital", style: .dolby))
        }

        if !formatImpliesSurround, let channels = Self.surroundLabel(
            channelLayout: audio.channelLayout,
            channels: audio.channels
        ) {
            badges.append(MediaBadge(channels, style: .spec))
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
    }    /// A surround-channel label (`7.1`, `5.1`) from a layout string or channel
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
        return MediaBadge(officialRating, style: .rating)
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

    /// Runtime text for poster/landscape cards:
    /// - overall runtime for movies/TV when not started;
    /// - remaining runtime (`"… left"`) while in progress.
    ///
    /// Hidden for non-video kinds and when runtime is unknown.
    var cardRuntimeText: String? {
        guard cardRuntimeEligible, let runtime, runtime > 0 else { return nil }
        if let remaining = remainingCardRuntimeText(for: runtime) {
            return remaining
        }
        return runtime.runtimeBadgeText
    }

    /// In-progress fraction (`0..<1`) for a resumable item, or `nil` when it has
    /// not been started or is already finished. Drives the detail Play button's
    /// small progress bar.
    var resumeProgressFraction: Double? { cardProgressFraction }

    /// Bare remaining-time text for an in-progress item (e.g. `20m`), or `nil`
    /// when it is not resumable. Shown inside the detail Play button (the cards
    /// use the longer "… left" form via `remainingCardRuntimeText`).
    var resumeRemainingText: String? {
        guard let runtime, runtime > 0 else { return nil }
        return remainingRuntimeLabel(for: runtime)
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

    private var cardRuntimeEligible: Bool {
        switch kind {
        case .movie, .series, .season, .episode:
            return true
        default:
            return false
        }
    }

    private var cardProgressFraction: Double? {
        guard !isPlayed else { return nil }
        if let runtime, runtime > 0, let resume = resumePosition, resume > 0 {
            return min(1, max(0, resume / runtime))
        }
        if let percentage = playedPercentage, percentage > 0, percentage < 1 {
            return min(1, max(0, percentage))
        }
        return nil
    }

    private func remainingCardRuntimeText(for runtime: TimeInterval) -> String? {
        guard let label = remainingRuntimeLabel(for: runtime) else { return nil }
        return "\(label) left"
    }

    /// The bare rounded remaining-time label (e.g. `20m`) for an in-progress item,
    /// or `nil` when it is not partially watched. The shared basis for both the
    /// card's "… left" text and the Play button's compact remaining time.
    private func remainingRuntimeLabel(for runtime: TimeInterval) -> String? {
        guard let progress = cardProgressFraction, progress > 0, progress < 1 else {
            return nil
        }
        let remainingSeconds = max(0, runtime * (1 - progress))
        guard remainingSeconds > 0 else { return nil }
        // Round up so in-progress cards don't show "0m" near completion.
        let roundedUpMinutes = max(1, Int(ceil(remainingSeconds / 60)))
        let roundedRemaining = TimeInterval(roundedUpMinutes * 60)
        return roundedRemaining.runtimeBadgeText
    }
}

// MARK: - Representative badges for a collection (series ← episodes)

public extension Sequence where Element == MediaItem {
    /// A representative technical-badge summary for a group of items — typically
    /// every loaded episode of a series or season. It reports the single best
    /// resolution, dynamic range and audio capabilities found anywhere in the
    /// group, mirroring how Apple TV summarises a show's top capabilities on its
    /// detail page (e.g. a show with one Dolby Vision / Atmos episode reads as
    /// "4K · Dolby Vision · Dolby Atmos"). Empty when no item carries stream
    /// metadata, so a series whose episodes lack media info shows nothing.
    var representativeTechnicalBadges: [MediaBadge] {
        MediaSourceMetadata.representativeTechnicalBadges(from: compactMap(\.mediaInfo))
    }
}

public extension MediaSourceMetadata {
    /// The best-of-each-category technical badge set across many sources. Unlike
    /// a single item's `technicalBadges`, this maximises resolution, dynamic
    /// range and audio independently so the summary reflects the group's peak
    /// capabilities rather than any one file's.
    static func representativeTechnicalBadges(from sources: [MediaSourceMetadata]) -> [MediaBadge] {
        guard !sources.isEmpty else { return [] }
        var badges: [MediaBadge] = []

        if let resolution = sources
            .compactMap(\.resolutionBadge)
            .max(by: { resolutionRank($0.label) < resolutionRank($1.label) }) {
            badges.append(resolution)
        }

        if let range = sources
            .flatMap(\.dynamicRangeBadges)
            .max(by: { dynamicRangeRank($0.label) < dynamicRangeRank($1.label) }) {
            badges.append(range)
        }

        // Maximise the headline audio format and the surround layout separately,
        // then suppress the channel badge when the winning format already implies
        // surround (Atmos/DTS:X/TrueHD), matching the single-item rule.
        let audioBadges = sources.flatMap(\.audioBadges)
        let bestFormat = audioBadges
            .filter { audioFormatRank($0.label) > 0 }
            .max(by: { audioFormatRank($0.label) < audioFormatRank($1.label) })
        let bestChannels = audioBadges
            .filter { channelRank($0.label) > 0 }
            .max(by: { channelRank($0.label) < channelRank($1.label) })
        if let bestFormat {
            badges.append(bestFormat)
            if !formatImpliesSurround(bestFormat.label), let bestChannels {
                badges.append(bestChannels)
            }
        } else if let bestChannels {
            badges.append(bestChannels)
        }

        return badges
    }

    private static func resolutionRank(_ label: String) -> Int {
        switch label {
        case "4K": return 5
        case "1440p": return 4
        case "1080p": return 3
        case "720p": return 2
        case "SD": return 1
        default: return 0
        }
    }

    private static func dynamicRangeRank(_ label: String) -> Int {
        switch label {
        case "Dolby Vision": return 5
        case "HDR10+": return 4
        case "HDR10": return 3
        case "HLG": return 2
        case "HDR": return 1
        default: return 0
        }
    }

    private static func audioFormatRank(_ label: String) -> Int {
        switch label {
        case "Dolby Atmos": return 6
        case "DTS:X": return 5
        case "Dolby TrueHD": return 4
        case "DTS-HD": return 3
        case "Dolby Digital+": return 2
        case "Dolby Digital": return 1
        default: return 0
        }
    }

    private static func channelRank(_ label: String) -> Int {
        switch label {
        case "7.1": return 2
        case "5.1": return 1
        default: return 0
        }
    }

    private static func formatImpliesSurround(_ label: String) -> Bool {
        label == "Dolby Atmos" || label == "DTS:X" || label == "Dolby TrueHD"
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
