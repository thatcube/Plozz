import Foundation

public enum GenreDisplayFormatter {
    public static func displayName(for genre: String) -> String {
        let trimmed = genre.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = trimmed.lowercased().unicodeScalars
            .filter(CharacterSet.alphanumerics.contains)
            .map(String.init)
            .joined()
        switch key {
        case "sciencefiction", "scifi", "scifiction":
            return "Sci-Fi"
        case "sciencefictionfantasy", "sciencefictionandfantasy",
             "scififantasy", "scifiandfantasy",
             "scifictionfantasy", "scifictionandfantasy":
            return "Sci-Fi & Fantasy"
        default:
            return trimmed
        }
    }

    public static func displayNames(for genres: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = genres.compactMap { genre -> String? in
            let displayName = displayName(for: genre)
            guard !displayName.isEmpty,
                  seen.insert(displayName.lowercased()).inserted else {
                return nil
            }
            return displayName
        }
        let compoundKey = "sci-fi & fantasy"
        if result.contains(where: { $0.lowercased() == compoundKey }) {
            result.removeAll {
                let key = $0.lowercased()
                return key == "sci-fi" || key == "fantasy"
            }
        }
        return result
    }
}

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
        /// A stylized HDR wordmark badge (`HDR10`, `HDR10+`, `HLG`, `HDR`)
        /// painted with a gradient border so it reads like the HDR logo rather
        /// than a plain spec pill.
        case hdr
        /// The standard-dynamic-range counterpart to `.hdr`: the same borderless
        /// heavy wordmark treatment, but filled with a muted, theme-aware
        /// brushed-metal sheen (a faint diagonal satin streak across neutral
        /// grays) instead of HDR's vibrant luminance gradient — a matte logo that
        /// reads as the deliberate "opposite of shiny".
        case sdr
        /// A Dolby badge rendered as the double-D logo with a stacked wordmark
        /// (`Dolby` over the format, e.g. Dolby Vision / Atmos / Digital+). No
        /// pill.
        case dolby
        /// A DTS badge rendered as a custom `dts:X` / `dts-HD` wordmark logo
        /// (lowercase `dts` with an emphasized format suffix). No pill.
        case dts
    }

    public var label: String
    public var style: Style
    /// Optional trailing detail rendered as plain text after a logo-style badge
    /// (`.dolby`/`.dts`) — e.g. the channel layout `5.1`/`7.1`, so the format
    /// logo and its channel count read as one unit with no separate pill.
    public var detail: String?

    public var id: String { "\(style.rawValue):\(label):\(detail ?? "")" }

    public init(_ label: String, style: Style = .spec, detail: String? = nil) {
        self.label = label
        self.style = style
        self.detail = detail
    }

    /// A spoken/described form combining the label with any trailing detail
    /// (e.g. `Dolby Digital+ 5.1`).
    public var accessibilityText: String {
        guard let detail, !detail.isEmpty else { return label }
        return "\(label) \(detail)"
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
        // Classify by effective lines (max of true height and the height this
        // width implies at 16:9) so letterboxed cinematic content — e.g. a
        // 1920×804 movie — reads by its real width (1080p) rather than its
        // cropped height (which would wrongly read 720p).
        guard let lines = PlaybackDiagnostics.effectiveResolutionLines(
            width: video.width,
            height: video.height
        ) else {
            return nil
        }
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

    /// Dynamic-range badge(s) describing the HDR/Dolby Vision signal. A pure
    /// Dolby Vision stream reads `Dolby Vision` alone; a Dolby Vision stream that
    /// also carries an HDR10 base layer (Jellyfin's `DOVIWithHDR10`, Plex's
    /// "DoVi/HDR10") reads `Dolby Vision` **and** `HDR10` so the badge row
    /// advertises both. Otherwise a single `HDR10+`, `HDR10`, `HLG`, or generic
    /// `HDR` badge, or `SDR` for standard-range content. Empty only when there's
    /// nothing to classify. HDR badges use the `.hdr` logo style; Dolby Vision
    /// uses the `.dolby` mark; `SDR` is a plain `.spec` pill.
    var dynamicRangeBadges: [MediaBadge] {
        guard let video else { return [] }
        let rangeType = (video.videoRangeType ?? "").uppercased()
        let range = (video.videoRange ?? "").uppercased()

        if rangeType.hasPrefix("DOVI") || rangeType.contains("DOLBY") || range == "DOVI" {
            var badges = [MediaBadge("Dolby Vision", style: .dolby)]
            // DoVi profiles 7/8 ship an HDR10 base layer; surface it as a second
            // badge so a "DoVi/HDR10" file shows both. Pure DoVi (profile 5)
            // carries no HDR10 fallback and shows Dolby Vision alone.
            if rangeType.contains("HDR10PLUS") || rangeType.contains("HDR10+") {
                badges.append(MediaBadge("HDR10+", style: .hdr))
            } else if rangeType.contains("HDR10") {
                badges.append(MediaBadge("HDR10", style: .hdr))
            }
            return badges
        }
        if rangeType.contains("HDR10PLUS") || rangeType.contains("HDR10+") {
            return [MediaBadge("HDR10+", style: .hdr)]
        }
        if rangeType.hasPrefix("HDR10") {
            return [MediaBadge("HDR10", style: .hdr)]
        }
        if rangeType == "HLG" || rangeType.hasPrefix("HLG") {
            return [MediaBadge("HLG", style: .hdr)]
        }
        if rangeType.hasPrefix("HDR") || range == "HDR" {
            return [MediaBadge("HDR", style: .hdr)]
        }
        // No HDR signal → standard dynamic range. Only assert SDR when we have
        // an explicit range token to back it up. Providers like Jellyfin emit a
        // literal `SDR` token; Plex's coarse media-level fallback emits nothing,
        // and in that case dimensions alone don't prove SDR — a 4K HEVC episode
        // may still be DoVi/HDR even when the trimmed children response strips
        // the HDR display-title hint. Staying silent then lets us show
        // "4K · Dolby Atmos" rather than a misleading "4K · SDR" pill.
        let hasRangeToken = !range.isEmpty || !rangeType.isEmpty
        if hasRangeToken {
            return [MediaBadge("SDR", style: .sdr)]
        }
        return []
    }

    /// A badge naming the video codec family (`HEVC`, `H.264`, `AV1`, `VP9`, …),
    /// or `nil` when the source reports no codec. This is the "(HEVC)" / "(H.264)"
    /// detail Plex shows alongside the resolution; the full codec profile lives in
    /// the playback-diagnostics overlay.
    var videoCodecBadge: MediaBadge? {
        guard let video,
              let name = PlaybackDiagnostics.friendlyCodecName(video.codec),
              !name.isEmpty,
              // The Dolby Vision case is already conveyed by the dynamic-range
              // badge, so don't repeat it here if a codec *tag* folded to it.
              name != "Dolby Vision" else {
            return nil
        }
        return MediaBadge(name, style: .spec)
    }

    /// Audio capability badges: a single headline format badge (Dolby Atmos,
    /// DTS:X, Dolby TrueHD, DTS-HD, Dolby Digital+/Dolby Digital) carrying the
    /// channel layout (`5.1`/`7.1`) as a trailing `detail` when the format isn't
    /// already object-based surround. When no headline format is present, a bare
    /// channel badge is emitted instead.
    var audioBadges: [MediaBadge] {
        guard let audio else { return [] }
        let profile = (audio.profile ?? "").lowercased()
        let codec = (audio.codec ?? "").lowercased()

        // Object-based / lossless headline formats imply surround on their own,
        // so they suppress the trailing channel detail below.
        var format: MediaBadge?
        var formatImpliesSurround = false
        if profile.contains("atmos") {
            format = MediaBadge("Dolby Atmos", style: .dolby)
            formatImpliesSurround = true
        } else if profile.contains("dts:x") || profile.contains("dtsx") || profile.contains("dts x") {
            format = MediaBadge("DTS:X", style: .dts)
            formatImpliesSurround = true
        } else if codec == "truehd" {
            format = MediaBadge("Dolby TrueHD", style: .dolby)
            formatImpliesSurround = true
        } else if codec == "dts" && (profile.contains("hd") || profile.contains("ma")) {
            format = MediaBadge("DTS-HD", style: .dts)
        } else if codec == "eac3" {
            format = MediaBadge("Dolby Digital+", style: .dolby)
        } else if codec == "ac3" {
            format = MediaBadge("Dolby Digital", style: .dolby)
        }

        let channels = formatImpliesSurround ? nil : Self.surroundLabel(
            channelLayout: audio.channelLayout,
            channels: audio.channels
        )

        if var format {
            format.detail = channels
            return [format]
        } else if let channels {
            return [MediaBadge(channels, style: .spec)]
        }
        return []
    }

    /// The full ordered technical badge set: resolution, then the Dolby-family
    /// badges grouped together (Dolby Vision before audio Dolby badges), then
    /// the HDR10 / HDR / SDR pill, then any non-Dolby audio badges. The video
    /// codec (HEVC / H.264) is intentionally omitted from the headline badge
    /// row; the full codec profile remains in the playback-diagnostics overlay.
    ///
    /// Grouping keeps the two visually-similar Dolby logos (e.g. Dolby Vision +
    /// Dolby Atmos) adjacent rather than separated by an `HDR10` pill, mirroring
    /// how Apple TV composes "4K · Dolby Vision · Dolby Atmos · HDR10".
    var technicalBadges: [MediaBadge] {
        Self.dolbyGroupedTechnicalBadges(
            resolution: resolutionBadge,
            range: dynamicRangeBadges,
            audio: audioBadges
        )
    }

    /// Composes a resolution/HDR/audio badge list in the Apple-TV-style Dolby
    /// grouped order — resolution, then any Dolby-styled range badges (Dolby
    /// Vision), then any Dolby-styled audio badges (Dolby Atmos, TrueHD,
    /// Digital+/Digital), then the remaining range badges (HDR10+, HDR10,
    /// HLG, HDR, SDR), then the remaining audio (DTS:X / DTS-HD / channels).
    ///
    /// Single source of truth for the ordering used by both an item's own
    /// `technicalBadges` and the cross-source `representativeTechnicalBadges`
    /// summary — they used to maintain inline copies that could drift.
    static func dolbyGroupedTechnicalBadges(
        resolution: MediaBadge?,
        range: [MediaBadge],
        audio: [MediaBadge]
    ) -> [MediaBadge] {
        var badges: [MediaBadge] = []
        if let resolution { badges.append(resolution) }
        let dolbyRange = range.filter { $0.style == .dolby }
        let otherRange = range.filter { $0.style != .dolby }
        let dolbyAudio = audio.filter { $0.style == .dolby }
        let otherAudio = audio.filter { $0.style != .dolby }
        badges.append(contentsOf: dolbyRange)
        badges.append(contentsOf: dolbyAudio)
        badges.append(contentsOf: otherRange)
        badges.append(contentsOf: otherAudio)
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

// MARK: - Per-version badges

public extension MediaVersion {
    /// Technical badges for this version. When the version carries the backing
    /// file's real ``MediaVersion/sourceMetadata`` (the same-account-duplicate
    /// case), they come straight from `MediaSourceMetadata.technicalBadges` —
    /// the authoritative path that correctly renders HDR10+, DoVi-with-HDR10 and
    /// channel-layout audio. Otherwise they're composed from this version's own
    /// flattened facts (resolution from width/height, HDR/DoVi from `videoRange`,
    /// audio from `audioProfile`/`audioCodec`/`audioChannels`), via the same
    /// Dolby-grouped ordering helper so a per-version row reads identically to
    /// the per-item one.
    ///
    /// The hero's badge row uses this when the user picks a non-default version
    /// from the picker, so switching from a 4K HDR Atmos Remux to a 720p SDR
    /// WEB-DL flips the badges to match the *selected* file rather than the
    /// default's media-info snapshot.
    var technicalBadges: [MediaBadge] {
        // A version synthesised from a whole backing item carries that file's
        // real stream metadata — render through the authoritative path so the
        // badges match exactly what the file's own hero would show (no HDR10+
        // → SDR downgrade, no resolution loss from sparse flattened fields).
        if let sourceMetadata {
            return sourceMetadata.technicalBadges
        }
        let resolution: MediaBadge? = {
            // Reuse the effective-lines classifier so a 1920×804 cinematic
            // version still reads 1080p rather than 720p — matching how the
            // per-item resolutionBadge categorises the same file.
            guard let lines = PlaybackDiagnostics.effectiveResolutionLines(
                width: width,
                height: height
            ) else {
                if let label = resolutionLabel { return MediaBadge(label, style: .prominent) }
                return nil
            }
            let label: String
            switch lines {
            case 2000...: label = "4K"
            case 1400..<2000: label = "1440p"
            case 1000..<1400: label = "1080p"
            case 700..<1000: label = "720p"
            default: label = "SD"
            }
            return MediaBadge(label, style: .prominent)
        }()

        let range: [MediaBadge] = {
            let normalized = (videoRange ?? "").uppercased()
                .replacingOccurrences(of: "+", with: "PLUS")
                .replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "_", with: "")
                .replacingOccurrences(of: "-", with: "")
            if normalized == "HDR10PLUS" {
                return [MediaBadge("HDR10+", style: .hdr)]
            }
            guard let token = videoRange, let hdr = HDRRange(rawValue: token) else { return [] }
            switch hdr {
            case .sdr: return [MediaBadge("SDR", style: .sdr)]
            case .hlg: return [MediaBadge("HLG", style: .hdr)]
            case .hdr10: return [MediaBadge("HDR10", style: .hdr)]
            case .dolbyVision, .dolbyVisionWithSDR:
                return [MediaBadge("Dolby Vision", style: .dolby)]
            case .dolbyVisionWithHDR10:
                return [MediaBadge("Dolby Vision", style: .dolby),
                        MediaBadge("HDR10", style: .hdr)]
            case .dolbyVisionWithHLG:
                return [MediaBadge("Dolby Vision", style: .dolby),
                        MediaBadge("HLG", style: .hdr)]
            }
        }()

        let audio: [MediaBadge] = {
            let profile = (audioProfile ?? "").lowercased()
            let codec = (audioCodec ?? "").lowercased()
            var format: MediaBadge?
            var formatImpliesSurround = false
            if profile.contains("atmos") {
                format = MediaBadge("Dolby Atmos", style: .dolby)
                formatImpliesSurround = true
            } else if profile.contains("dts:x") || profile.contains("dtsx") || profile.contains("dts x") {
                format = MediaBadge("DTS:X", style: .dts)
                formatImpliesSurround = true
            } else if codec == "truehd" {
                format = MediaBadge("Dolby TrueHD", style: .dolby)
                formatImpliesSurround = true
            } else if codec == "dts" && (profile.contains("hd") || profile.contains("ma")) {
                format = MediaBadge("DTS-HD", style: .dts)
            } else if codec == "eac3" {
                format = MediaBadge("Dolby Digital+", style: .dolby)
            } else if codec == "ac3" {
                format = MediaBadge("Dolby Digital", style: .dolby)
            }

            let channels: String? = {
                if formatImpliesSurround { return nil }
                switch audioChannels {
                case .some(let c) where c >= 8: return "7.1"
                case .some(let c) where c >= 6: return "5.1"
                default: return nil
                }
            }()

            if var format {
                format.detail = channels
                return [format]
            } else if let channels {
                return [MediaBadge(channels, style: .spec)]
            }
            return []
        }()

        return MediaSourceMetadata.dolbyGroupedTechnicalBadges(
            resolution: resolution,
            range: range,
            audio: audio
        )
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
        parts.append(
            contentsOf: GenreDisplayFormatter.displayNames(
                for: Array(genres.prefix(maxGenres))
            )
        )
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
    /// capabilities rather than any one file's. Output order matches
    /// `MediaSourceMetadata.technicalBadges`: resolution → Dolby Vision → Dolby
    /// audio → HDR10/HDR/SDR → non-Dolby audio, so the two Dolby logos stay
    /// adjacent (e.g. "4K · Dolby Vision · Dolby Atmos · HDR10").
    static func representativeTechnicalBadges(from sources: [MediaSourceMetadata]) -> [MediaBadge] {
        guard !sources.isEmpty else { return [] }
        var resolution: MediaBadge?
        var audioBadge: MediaBadge?

        if let r = sources
            .compactMap(\.resolutionBadge)
            .max(by: { resolutionRank($0.label) < resolutionRank($1.label) }) {
            resolution = r
        }

        // Pick the source whose dynamic-range set contains the best-ranked badge
        // and adopt that source's FULL range list, so a DoVi/HDR10 source
        // contributes both `Dolby Vision` AND `HDR10` rather than just the top
        // rank. Falls back to flat-max when no source has a non-empty set.
        let rangeArrays = sources.map(\.dynamicRangeBadges).filter { !$0.isEmpty }
        var rangeBadges: [MediaBadge] = []
        if let best = rangeArrays.max(by: { topRank(of: $0) < topRank(of: $1) }) {
            rangeBadges = best
        }

        // Maximise the headline audio format and the surround layout separately,
        // then attach the best channel layout to the winning format as a trailing
        // detail — unless that format already implies surround (Atmos/DTS:X/
        // TrueHD). Channel info may live on a format badge's `detail` or as a
        // standalone channel badge's label.
        let audioBadges = sources.flatMap(\.audioBadges)
        let bestFormat = audioBadges
            .filter { audioFormatRank($0.label) > 0 }
            .max(by: { audioFormatRank($0.label) < audioFormatRank($1.label) })
        let channelCandidates = audioBadges.flatMap { badge -> [String] in
            var candidates: [String] = []
            if let detail = badge.detail { candidates.append(detail) }
            if channelRank(badge.label) > 0 { candidates.append(badge.label) }
            return candidates
        }
        let bestChannels = channelCandidates.max(by: { channelRank($0) < channelRank($1) })
        if var bestFormat {
            bestFormat.detail = formatImpliesSurround(bestFormat.label) ? nil : bestChannels
            audioBadge = bestFormat
        } else if let bestChannels {
            audioBadge = MediaBadge(bestChannels, style: .spec)
        }

        // Compose the same Dolby-grouped order as `technicalBadges` via the
        // shared helper, so resolution/HDR/audio ordering lives in exactly one
        // place.
        return dolbyGroupedTechnicalBadges(
            resolution: resolution,
            range: rangeBadges,
            audio: audioBadge.map { [$0] } ?? []
        )
    }

    /// Highest `dynamicRangeRank` across a badge array, used to pick the source
    /// with the strongest dynamic-range set when summarising a series.
    private static func topRank(of badges: [MediaBadge]) -> Int {
        badges.map { dynamicRangeRank($0.label) }.max() ?? 0
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
