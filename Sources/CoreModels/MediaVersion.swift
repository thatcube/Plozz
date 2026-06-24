import Foundation

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
/// (b) predict — against the running Apple TV's `MediaCapabilities` — whether a
/// version will **Direct Play** or have to **Transcode** on *this* device, which
/// powers the smart default selection and the per-row compatibility badge.
public struct MediaVersion: Codable, Hashable, Identifiable, Sendable {
    /// Provider media-source id; threaded into `playbackInfo(for:mediaSourceID:)`.
    public var id: String
    /// Raw provider-supplied source name (Jellyfin `MediaSources[].Name`), e.g.
    /// "Movie (2009) Bluray-2160p Atmos". `nil` when the server reports none.
    public var name: String?
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

    public init(
        id: String,
        name: String? = nil,
        edition: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        bitrate: Int? = nil,
        sizeBytes: Int64? = nil,
        isDefault: Bool = false,
        videoCodec: String? = nil,
        videoRange: String? = nil,
        audioCodec: String? = nil,
        audioChannels: Int? = nil,
        audioProfile: String? = nil,
        container: String? = nil
    ) {
        self.id = id
        self.name = name
        self.edition = edition
        self.width = width
        self.height = height
        self.bitrate = bitrate
        self.sizeBytes = sizeBytes
        self.isDefault = isDefault
        self.videoCodec = videoCodec
        self.videoRange = videoRange
        self.audioCodec = audioCodec
        self.audioChannels = audioChannels
        self.audioProfile = audioProfile
        self.container = container
    }

    /// A short resolution label derived from the video height, e.g. `4K`,
    /// `1080p`, `720p`. `nil` when the height is unknown.
    public var resolutionLabel: String? {
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

    /// Whether this version carries any HDR (non-SDR) video range.
    public var isHDR: Bool {
        guard let token = videoRange, let range = HDRRange(rawValue: token) else { return false }
        return range != .sdr
    }

    /// A compact HDR badge label, e.g. `Dolby Vision`, `HDR10`, `HLG`, or `nil`
    /// for SDR/unknown — used in the version diff row.
    public var hdrLabel: String? {
        guard let token = videoRange, let range = HDRRange(rawValue: token) else { return nil }
        switch range {
        case .sdr: return nil
        case .hlg: return "HLG"
        case .hdr10: return "HDR10"
        case .dolbyVision, .dolbyVisionWithHDR10, .dolbyVisionWithHLG, .dolbyVisionWithSDR:
            return "Dolby Vision"
        }
    }

    /// A compact audio badge label, e.g. `Atmos`, `7.1`, `5.1`, `Stereo`.
    public var audioLabel: String? {
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
        guard let sizeBytes, sizeBytes > 0 else { return nil }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: sizeBytes)
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

/// How a `MediaVersion` is predicted to play on a specific device, derived purely
/// from the version's codec/range/audio facts and a `MediaCapabilities` snapshot.
public enum VersionPlaybackCompatibility: String, Sendable, Equatable {
    /// Every stream is natively decodable/passable: the server can hand the file
    /// over untouched (best quality, lowest server load).
    case directPlay
    /// At least one stream (video codec, HDR range, or audio codec) isn't
    /// supported by this device/route, so the server will have to transcode.
    case transcode
    /// Not enough information to decide (e.g. the provider reported no codec).
    case unknown

    /// A short tag for the picker row.
    public var badge: String {
        switch self {
        case .directPlay: return "Direct Play"
        case .transcode: return "Transcode"
        case .unknown: return ""
        }
    }
}

public extension MediaVersion {
    /// Predicts whether this version Direct Plays or Transcodes on the device
    /// described by `capabilities`. Reuses the same policy helpers both providers
    /// already use for their server device-profiles, so the prediction matches
    /// what the server will actually decide.
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
    /// **highest-quality version that Direct Plays** on this device, so the user
    /// gets the best experience their Apple TV can actually present without a
    /// server transcode. Falls back to the server default, then the
    /// highest-quality version overall, then the first entry.
    ///
    /// This is the heart of the "smart selection" creative addition — it turns a
    /// dumb list into a one-tap "right thing for *this* TV" while still letting
    /// the user override to any other version.
    func recommendedSelection(for capabilities: MediaCapabilities) -> MediaVersion? {
        guard !isEmpty else { return nil }
        let directPlayable = filter { $0.compatibility(with: capabilities) == .directPlay }
        if let best = directPlayable.max(by: { $0.qualityScore < $1.qualityScore }) {
            return best
        }
        if let serverDefault = first(where: { $0.isDefault }) { return serverDefault }
        if let best = self.max(by: { $0.qualityScore < $1.qualityScore }) { return best }
        return first
    }
}
