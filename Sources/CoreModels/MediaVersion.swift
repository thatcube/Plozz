import Foundation

public enum MediaFileSizeFormatter {
    public static func string(fromByteCount bytes: Int64?) -> String? {
        string(fromByteCount: bytes, locale: .autoupdatingCurrent)
    }

    static func string(fromByteCount bytes: Int64?, locale: Locale) -> String? {
        guard let bytes, bytes > 0 else { return nil }
        let gigabyte = 1_000_000_000.0
        let megabyte = 1_000_000.0
        let usesGigabytes = Double(bytes) >= gigabyte
        let value = Double(bytes) / (usesGigabytes ? gigabyte : megabyte)
        let formatted = value.formatted(
            .number.precision(.fractionLength(0...1))
                .locale(locale)
        )
        return "\(formatted) \(usesGigabytes ? "GB" : "MB")"
    }
}

/// One selectable media source ("version") of a title — e.g. a 4K HDR Atmos
/// remux alongside a 1080p web-dl. Provider-agnostic: Jellyfin maps each
/// `MediaSources` entry onto one of these, Plex each `Media` entry.
///
/// A title with zero or one version shows no picker; two or more surface a
/// "Version" control on the detail hero so the user can choose which source
/// `Play` targets. The `id` is the provider's media-source id, threaded back
/// into `playbackInfo(for:mediaSourceID:)` so playback resolves the chosen file.
///
/// Beyond the label/size the brief requires, this also carries the handful of
/// technical facts (`videoCodec`, `videoRange`, `audioCodec`, `audioChannels`)
/// needed to (a) render a tasteful "4K · Dolby Vision · Atmos" diff per row and
/// (b) provide a conservative native-profile ordering hint. The actual delivery
/// mode is known only after provider resolution and is shown in Playback
/// Diagnostics, never guessed in the version menu.
public struct MediaVersion: Codable, Hashable, Identifiable, Sendable {
    /// Provider media-source id; threaded into `playbackInfo(for:mediaSourceID:)`.
    public var id: String
    /// Raw provider-supplied source name (Jellyfin `MediaSources[].Name`), e.g.
    /// "Movie (2009) Bluray-2160p Atmos". `nil` when the server reports none.
    public var name: String?
    /// Basename of the backing file, including its extension, when the provider
    /// exposes a path. The full server path is never stored or presented.
    public var fileName: String?
    /// The edition / cut of the title when the provider states it *explicitly*
    /// (e.g. Plex's `editionTitle`: "Director's Cut", "Theatrical"). Takes
    /// precedence over anything parsed from `name`. `nil` when the provider
    /// reports no explicit edition, in which case `editionLabel` falls back to
    /// parsing `name`.
    public var edition: String?
    /// Pixel width of the video stream, when known.
    public var width: Int?
    /// Pixel height of the video stream, when known (drives `resolutionLabel`).
    public var height: Int?
    /// Overall declared bitrate in bits/sec, when known.
    public var bitrate: Int?
    /// File size in bytes, when known (drives the human-readable size in the label).
    public var sizeBytes: Int64?
    /// Runtime of this specific file in seconds, when known.
    public var duration: TimeInterval?
    /// The server's default/primary source — used as the selection fallback when
    /// no version direct-plays and as a tie-breaker.
    public var isDefault: Bool

    // Technical facts for the visual diff + device compatibility prediction.

    /// Lowercased video codec token, e.g. `hevc`, `h264`, `av1`.
    public var videoCodec: String?
    /// HDR range token matching `HDRRange.rawValue` (e.g. `HDR10`, `DOVI`, `SDR`).
    public var videoRange: String?
    /// Lowercased audio codec token, e.g. `eac3`, `dts`, `truehd`.
    public var audioCodec: String?
    /// Audio channel count, e.g. `6` (5.1), `8` (7.1).
    public var audioChannels: Int?
    /// Audio profile label, e.g. `Dolby Atmos`, `DTS-HD MA`.
    public var audioProfile: String?
    /// Original container, e.g. `mkv`, `mp4`.
    public var container: String?

    /// When this version is backed by a **different** provider item than the one
    /// containing it (the same-account-duplicate case: two separate Jellyfin
    /// movie items for the same film), the backing item's id. Playback must
    /// repoint to this id before resolving the stream. `nil` when the version is
    /// an "intrinsic" `MediaSources` entry on the containing item (the
    /// traditional multi-version case where one item exposes several files).
    public var sourceItemID: String?
    /// The account that owns ``sourceItemID``. Set whenever ``sourceItemID`` is.
    public var sourceAccountID: String?

    /// The **real** per-file stream metadata this version was built from, when it
    /// was synthesised from a whole backing item (the same-account-duplicate
    /// case). Carried verbatim so this version's badges and quality are derived
    /// through the rich, authoritative `MediaSourceMetadata` path — the SAME one
    /// a single item's hero uses — rather than re-derived from the lossy
    /// flattened fields above. That flattening can't represent HDR10+ (there is
    /// no `HDRRange` case for it) or per-channel-layout audio, so without this a
    /// 4K Dolby Vision / HDR10+ / Atmos file regressed to "720p · SDR" in the
    /// hero. `nil` for provider-intrinsic versions, whose flattened fields are
    /// already authoritative.
    public var sourceMetadata: MediaSourceMetadata?

    public init(
        id: String,
        name: String? = nil,
        fileName: String? = nil,
        edition: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        bitrate: Int? = nil,
        sizeBytes: Int64? = nil,
        duration: TimeInterval? = nil,
        isDefault: Bool = false,
        videoCodec: String? = nil,
        videoRange: String? = nil,
        audioCodec: String? = nil,
        audioChannels: Int? = nil,
        audioProfile: String? = nil,
        container: String? = nil,
        sourceItemID: String? = nil,
        sourceAccountID: String? = nil,
        sourceMetadata: MediaSourceMetadata? = nil
    ) {
        self.id = id
        self.name = name
        self.fileName = fileName
        self.edition = edition
        self.width = width
        self.height = height
        self.bitrate = bitrate
        self.sizeBytes = sizeBytes
        self.duration = duration
        self.isDefault = isDefault
        self.videoCodec = videoCodec
        self.videoRange = videoRange
        self.audioCodec = audioCodec
        self.audioChannels = audioChannels
        self.audioProfile = audioProfile
        self.container = container
        self.sourceItemID = sourceItemID
        self.sourceAccountID = sourceAccountID
        self.sourceMetadata = sourceMetadata
    }

    /// Synthesises a single ``MediaVersion`` describing `item`'s lone backing
    /// file, used when same-account duplicate items (two distinct provider items
    /// for the same movie) are grouped into one detail page: each duplicate
    /// contributes one synthesised version, the version picker lists them
    /// together, and the carried `sourceItemID`/`sourceAccountID` lets playback
    /// repoint to the chosen backing item.
    ///
    /// The synthesised version carries the backing item's **real**
    /// `MediaSourceMetadata` (`sourceMetadata`) so its badges and quality render
    /// through the authoritative rich path — identical to how the same file's
    /// hero reads when opened directly — rather than a lossy re-derivation. The
    /// flattened `width`/`height`/`videoCodec`/… fields are still populated for
    /// the lightweight `displayLabel`/`compatibility` consumers.
    public static func synthesized(from item: MediaItem) -> MediaVersion {
        let video = item.mediaInfo?.video
        let audio = item.mediaInfo?.audio
        return MediaVersion(
            // Prefix the id so it can never collide with a real Jellyfin
            // `MediaSources[].Id` (a uuid) — if a synthesized id ever leaked
            // through the play path as a `MediaSourceId`, Jellyfin would
            // ignore it; with the prefix that ambiguity is impossible. The
            // playable backing item is carried by `sourceItemID`.
            id: "synth:\(item.id)",
            name: nil,
            fileName: item.mediaInfo?.fileName,
            width: video?.width,
            height: video?.height,
            bitrate: video?.bitrate,
            sizeBytes: item.mediaInfo?.fileSizeBytes,
            duration: item.runtime,
            isDefault: false,
            videoCodec: video?.codec,
            videoRange: video?.videoRangeType ?? video?.videoRange,
            audioCodec: audio?.codec,
            audioChannels: audio?.channels,
            audioProfile: audio?.profile,
            container: item.mediaInfo?.container,
            sourceItemID: item.id,
            sourceAccountID: item.sourceAccountID,
            sourceMetadata: item.mediaInfo
        )
    }

    /// A short resolution label derived from the video height, e.g. `4K`,
    /// `1080p`, `720p`. `nil` when the height is unknown. When real
    /// `sourceMetadata` is present its authoritative classifier wins (it reads
    /// effective lines from width too, so a letterboxed 1920×804 file reads
    /// 1080p rather than 720p).
    public var resolutionLabel: String? {
        if let sourceMetadata, let badge = sourceMetadata.resolutionBadge { return badge.label }
        guard let height else { return nil }
        switch height {
        case 4321...: return "8K"
        case 1601...4320: return "4K"
        case 1081...1600: return "1440p"
        case 901...1080: return "1080p"
        case 651...900: return "720p"
        case 1...650: return "SD"
        default: return nil
        }
    }

    /// Whether this version carries any HDR (non-SDR) video range. Prefers the
    /// authoritative `sourceMetadata` range classification when present so
    /// HDR10+ (which has no `HDRRange` case) still counts as HDR.
    public var isHDR: Bool {
        if let sourceMetadata {
            return sourceMetadata.dynamicRangeBadges.contains { $0.style == .hdr || $0.style == .dolby }
        }
        if normalizedVideoRange == "HDR10PLUS" { return true }
        guard let token = videoRange, let range = HDRRange(rawValue: token) else { return false }
        return range != .sdr
    }

    /// A compact HDR badge label, e.g. `Dolby Vision`, `HDR10`, `HDR10+`, `HLG`,
    /// or `nil` for SDR/unknown — used in the version diff row. Prefers the
    /// authoritative `sourceMetadata` classification (so HDR10+ is preserved).
    public var hdrLabel: String? {
        if let sourceMetadata {
            let range = sourceMetadata.dynamicRangeBadges
            if range.contains(where: { $0.style == .dolby }) { return "Dolby Vision" }
            if let hdr = range.first(where: { $0.style == .hdr }) { return hdr.label }
            return nil
        }
        if normalizedVideoRange == "HDR10PLUS" { return "HDR10+" }
        guard let token = videoRange, let range = HDRRange(rawValue: token) else { return nil }
        switch range {
        case .sdr: return nil
        case .hlg: return "HLG"
        case .hdr10: return "HDR10"
        case .dolbyVision, .dolbyVisionWithHDR10, .dolbyVisionWithHLG, .dolbyVisionWithSDR:
            return "Dolby Vision"
        }
    }

    private var normalizedVideoRange: String {
        (videoRange ?? "").uppercased()
            .replacingOccurrences(of: "+", with: "PLUS")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
    }

    /// A compact audio badge label, e.g. `Atmos`, `7.1`, `5.1`, `Stereo`.
    /// Prefers the authoritative `sourceMetadata` audio classification.
    public var audioLabel: String? {
        if let sourceMetadata, let headline = sourceMetadata.audioBadges.first {
            return headline.label
        }
        if let profile = audioProfile, profile.lowercased().contains("atmos") { return "Atmos" }
        switch audioChannels {
        case .some(let c) where c >= 8: return "7.1"
        case .some(let c) where c >= 6: return "5.1"
        case .some(let c) where c >= 2: return "Stereo"
        default:
            return audioCodec.map { $0.uppercased() }
        }
    }

    /// A human-readable file size, e.g. `12.4 GB`, or `nil` when unknown.
    public var sizeLabel: String? {
        MediaFileSizeFormatter.string(fromByteCount: sizeBytes)
    }

    /// A compact overall bitrate, e.g. `80 Mbps`.
    public var bitrateLabel: String? {
        guard let bitrate, bitrate > 0 else { return nil }
        let megabits = Double(bitrate) / 1_000_000
        let value = megabits.formatted(.number.precision(.fractionLength(0...1)))
        return "\(value) Mbps"
    }

    /// Runtime of this file in the app's compact duration style.
    public var durationLabel: String? {
        duration?.runtimeBadgeText
    }

    /// The edition / cut to surface for this version: the provider's explicit
    /// `edition` when present, otherwise one parsed from the source `name`
    /// (Extended, Theatrical, Director's Cut, …). `nil` when neither names a cut.
    /// This is the signal that distinguishes two otherwise-identical "4K · 12 GB"
    /// files, so the picker leads with it.
    public var editionLabel: String? {
        if let edition {
            let trimmed = edition.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return EditionParser.edition(from: name)
    }

    /// The source-quality token parsed from `name` (Remux, BluRay, WEB-DL, …), or
    /// `nil` when the name names no recognised source. Distinguishes a lossless
    /// Remux from a re-encoded WEB-DL that would otherwise read identically.
    public var sourceQualityLabel: String? {
        EditionParser.sourceQuality(from: name)
    }

    /// The primary user-facing label for a picker row. Leads with the **edition**
    /// (the cut — the thing users actually choose between) when known, then the
    /// derived "4K · HDR · Remux · 12.4 GB" quality facts, so two files of the
    /// same resolution are never indistinguishable. Falls back to the provider's
    /// own source `name`, then a generic "Version".
    public var displayLabel: String {
        var parts: [String] = []
        if let editionLabel { parts.append(editionLabel) }
        if let resolutionLabel { parts.append(resolutionLabel) }
        if let hdrLabel { parts.append(hdrLabel) }
        if let sourceQualityLabel { parts.append(sourceQualityLabel) }
        if let sizeLabel { parts.append(sizeLabel) }
        if !parts.isEmpty { return parts.joined(separator: " · ") }
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        return "Version"
    }

    /// First line of a rich version row. The edition/cut is the strongest
    /// differentiator; resolution is the fallback.
    public var menuTitle: String {
        if let editionLabel { return editionLabel }
        if let resolutionLabel { return resolutionLabel }
        if let name {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return "Version"
    }

    /// Technical facts that help distinguish files without claiming a playback
    /// outcome. Filename remains a separate tertiary line.
    public var menuFacts: [String] {
        var facts: [String] = []
        if menuTitle != resolutionLabel, let resolutionLabel { facts.append(resolutionLabel) }
        if let hdrLabel { facts.append(hdrLabel) }
        if let sourceQualityLabel { facts.append(sourceQualityLabel) }
        if let audioLabel { facts.append(audioLabel) }
        if let bitrateLabel { facts.append(bitrateLabel) }
        if let sizeLabel { facts.append(sizeLabel) }
        if let durationLabel { facts.append(durationLabel) }
        return facts
    }

    /// A coarse quality score used to order versions and pick a default. Driven
    /// primarily by resolution, then HDR, then bitrate — so "best available"
    /// sorts first. Deterministic and dependency-free.
    public var qualityScore: Int {
        var score = 0
        score += (height ?? 0)
        if isHDR { score += 4000 }
        if let bitrate { score += bitrate / 1_000_000 }
        if isDefault { score += 1 }
        return score
    }
}

// MARK: - Device compatibility prediction

/// A conservative native-profile heuristic derived only from flattened
/// codec/range/audio facts and a `MediaCapabilities` snapshot.
///
/// This is NOT the resolved playback outcome: it cannot account for container or
/// subtitle constraints, a provider's final playback decision, server remuxing,
/// or Plozzigen's broader on-device decode path. It may be used as an internal
/// ordering hint, but must never be shown as "Direct Play" / "Transcode" in UI.
public enum VersionPlaybackCompatibility: String, Sendable, Equatable {
    /// The known flattened facts fit the native device profile.
    case directPlay
    /// At least one known fact does not fit the native device profile. The provider
    /// or Plozzigen may still play/remux/decode it without a server transcode.
    case transcode
    /// Not enough information to decide (e.g. the provider reported no codec).
    case unknown
}

public extension MediaVersion {
    /// Classifies the version against the native device profile. This is only an
    /// ordering hint; see ``VersionPlaybackCompatibility`` for why it cannot
    /// predict the resolved provider/Plozzigen playback mode.
    func compatibility(with capabilities: MediaCapabilities) -> VersionPlaybackCompatibility {
        // Without a video codec we can't reason about it.
        guard let videoCodec, let codec = DirectPlayVideoCodec(rawValue: videoCodec.lowercased()) else {
            return .unknown
        }
        guard capabilities.allowedDirectPlayVideoCodecs.contains(codec) else { return .transcode }

        // HDR range: an unsupported range (e.g. Dolby Vision Profile-5 on a
        // non-DoVi display) forces a tone-mapped transcode.
        if let token = videoRange, let range = HDRRange(rawValue: token) {
            if !capabilities.allowedHDRRanges.contains(range) { return .transcode }
        } else if normalizedVideoRange == "HDR10PLUS",
                  !capabilities.allowedHDRRanges.contains(.hdr10) {
            return .transcode
        }

        // Audio: lossy AAC/MP3/etc. are always decodable on-device; the codecs
        // that need passthrough (AC-3/E-AC-3 always; DTS only with passthrough)
        // are gated through the capability policy.
        if let audioCodec {
            let token = audioCodec.lowercased()
            if let passthrough = PassthroughAudioCodec(rawValue: token),
               !capabilities.allowedPassthroughAudioCodecs.contains(passthrough) {
                return .transcode
            }
        }
        return .directPlay
    }
}

public extension Array where Element == MediaVersion {
    /// The version a freshly opened picker should select by default: the
    /// highest-quality version whose known facts fit the native device profile.
    /// This is a conservative ordering hint, not a claim about the provider's
    /// resolved delivery mode (Plozzigen may directly decode a version outside
    /// that profile). Falls back to the server default, then highest quality.
    ///
    /// This is the heart of the "smart selection" creative addition — it turns a
    /// dumb list into a one-tap "right thing for *this* TV" while still letting
    /// the user override to any other version.
    func recommendedSelection(for capabilities: MediaCapabilities) -> MediaVersion? {
        guard !isEmpty else { return nil }
        let nativeCompatible = filter { $0.compatibility(with: capabilities) == .directPlay }
        if let best = nativeCompatible.max(by: { $0.qualityScore < $1.qualityScore }) {
            return best
        }
        if let serverDefault = first(where: { $0.isDefault }) { return serverDefault }
        if let best = self.max(by: { $0.qualityScore < $1.qualityScore }) { return best }
        return first
    }

    /// A deterministic display order for the version picker. Known file sizes
    /// sort largest-first because they are the clearest scan-friendly proxy for
    /// source quality; unknown sizes follow, ordered by quality. Stable
    /// tiebreaks keep the order independent of insertion/arrival order.
    func sortedForPicker() -> [MediaVersion] {
        sorted { lhs, rhs in
            let lhsSize = lhs.sizeBytes.flatMap { $0 > 0 ? $0 : nil }
            let rhsSize = rhs.sizeBytes.flatMap { $0 > 0 ? $0 : nil }
            if lhsSize != rhsSize {
                if let lhsSize, let rhsSize { return lhsSize > rhsSize }
                return lhsSize != nil
            }
            if lhs.qualityScore != rhs.qualityScore { return lhs.qualityScore > rhs.qualityScore }
            if (lhs.height ?? 0) != (rhs.height ?? 0) { return (lhs.height ?? 0) > (rhs.height ?? 0) }
            let lhsKey = lhs.sourceItemID ?? lhs.id
            let rhsKey = rhs.sourceItemID ?? rhs.id
            if lhsKey != rhsKey { return lhsKey < rhsKey }
            return lhs.id < rhs.id
        }
    }
}
