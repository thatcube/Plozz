import Foundation

/// Persisted/debug-visible local-remux strategy choices. The ids are intentionally
/// string-backed so sibling branches can add new engines without rewriting a
/// closed enum contract across every caller.
public struct LocalRemuxStrategyChoice: Hashable, Sendable, Codable, Identifiable {
    public let id: String
    public let displayName: String
    public let detail: String

    public init(id: String, displayName: String, detail: String) {
        self.id = id
        self.displayName = displayName
        self.detail = detail
    }

    public static let disabledID = "disabled"
    public static let referenceServerRemuxID = "reference.server-remux"
    /// The production full-timeline localhost VOD remux engine (this branch). It
    /// is the default for eligible single-layer DoVi P5/8 + AC-3/E-AC-3 MKVs.
    public static let fullTimelineVODID = "fulltimeline.localhost-vod"
    public static let defaultID = fullTimelineVODID

    public static let disabled = LocalRemuxStrategyChoice(
        id: disabledID,
        displayName: "Off",
        detail: "Use normal routing. Eligible MKV Dolby Vision titles will stay on mpv."
    )

    public static let referenceServerRemux = LocalRemuxStrategyChoice(
        id: referenceServerRemuxID,
        displayName: "Server HLS baseline",
        detail: "Diagnostic baseline: force an AVPlayer HLS manifest so the Remux overlay and seek torture test actually run. Real local engines replace this."
    )

    public static let fullTimelineVOD = LocalRemuxStrategyChoice(
        id: fullTimelineVODID,
        displayName: "Full-timeline localhost VOD",
        detail: "App owns the stream: a loopback HTTP origin serves a full-timeline VOD HLS playlist (every segment declared up front) whose fMP4 segments are -c copy remuxed from the original MKV (dvh1 + dvcC/dvvC Dolby Vision, dec3 E-AC-3 Atmos, no re-encode). Every far seek resolves locally, so AVPlayer seek-ahead never 404s."
    )

    public static let builtInChoices: [LocalRemuxStrategyChoice] = [
        .disabled,
        .fullTimelineVOD,
        .referenceServerRemux
    ]

    /// Thread-safe holder for strategy choices contributed at launch by engine
    /// modules that link FFmpeg (e.g. the full-timeline VOD remux in LocalRemux).
    /// Keeping the *choice* registry in CoreModels — separate from
    /// FeaturePlayback's *factory* registry — lets persistence
    /// (`PlaybackPreferencesStore`) and display-name resolution (`choice(for:)`)
    /// recognise dynamic ids everywhere, without CoreModels knowing how to build a
    /// streamer.
    private final class DynamicChoiceRegistry: @unchecked Sendable {
        static let shared = DynamicChoiceRegistry()
        private let lock = NSLock()
        private var choices: [LocalRemuxStrategyChoice] = []

        func register(_ choice: LocalRemuxStrategyChoice) {
            lock.lock(); defer { lock.unlock() }
            choices.removeAll { $0.id == choice.id }
            choices.append(choice)
        }

        var all: [LocalRemuxStrategyChoice] {
            lock.lock(); defer { lock.unlock() }
            return choices
        }
    }

    /// Register (or replace, by id) a dynamically-contributed strategy choice.
    /// Idempotent: re-registering the same id updates its metadata in place.
    public static func registerDynamic(_ choice: LocalRemuxStrategyChoice) {
        DynamicChoiceRegistry.shared.register(choice)
    }

    /// Built-in choices followed by any dynamically-registered ones, de-duplicated
    /// by id (built-ins win). This is the canonical list the Remux overlay picker
    /// should present.
    public static var allChoices: [LocalRemuxStrategyChoice] {
        var result = builtInChoices
        for choice in DynamicChoiceRegistry.shared.all where !result.contains(where: { $0.id == choice.id }) {
            result.append(choice)
        }
        return result
    }

    public static func choice(for id: String) -> LocalRemuxStrategyChoice {
        allChoices.first(where: { $0.id == id }) ?? .disabled
    }
}

/// The authenticated original-file facts a local-remux strategy needs in order to
/// build its own AVPlayer-facing stream (localhost HLS, custom-scheme loader,
/// prefetch cache, ...).
public struct LocalRemuxSourceDescriptor: Hashable, Sendable {
    public var itemID: String
    public var mediaSourceID: String?
    public var provider: ProviderKind
    /// The original range-readable media bytes (typically an MKV part/download URL)
    /// with whatever auth the provider requires already embedded.
    public var originalURL: URL
    /// An already-playable AVPlayer URL for the same title, used by the shared
    /// reference strategy until a true local-remux engine replaces it.
    public var referencePlaybackURL: URL?
    public var durationSeconds: TimeInterval?
    public var byteRangeSupported: Bool
    public var sourceMetadata: MediaSourceMetadata

    public init(
        itemID: String,
        mediaSourceID: String? = nil,
        provider: ProviderKind,
        originalURL: URL,
        referencePlaybackURL: URL? = nil,
        durationSeconds: TimeInterval? = nil,
        byteRangeSupported: Bool = true,
        sourceMetadata: MediaSourceMetadata
    ) {
        self.itemID = itemID
        self.mediaSourceID = mediaSourceID
        self.provider = provider
        self.originalURL = originalURL
        self.referencePlaybackURL = referencePlaybackURL
        self.durationSeconds = durationSeconds
        self.byteRangeSupported = byteRangeSupported
        self.sourceMetadata = sourceMetadata
    }

    /// Why this source is, or is not, eligible for the local-remux AVPlayer path.
    public enum Eligibility: Equatable, Sendable {
        case eligible
        case ineligible(String)
    }

    /// The shared policy for when Plozz should prefer the native local-remux seam
    /// over the raw-MKV mpv path.
    ///
    /// **Default (narrow) gate** — single-layer Dolby Vision Profile 5 / 8.x in an
    /// MKV/Matroska container, Apple-decodable HEVC video, and AC-3 / E-AC-3 audio
    /// (including DD+ JOC Atmos). Profile 7 / TrueHD remain on the hybrid engine.
    ///
    /// **Widened gate** (`allowAnyDecodableHEVC == true`, B2 debug flag
    /// `com.plozz.playback.remuxHevcAny`) — accept *any* AVPlayer-decodable HEVC in
    /// an MKV with AC-3 / E-AC-3 audio, regardless of HDR signal: Dolby Vision
    /// (P5/8), HDR10, HDR10+, HLG, **or** SDR; 8- or 10-bit. The remux `-c copy`
    /// muxer handles HEVC + (e)ac3 identically for all of these, so routing them
    /// to remux→AVPlayer keeps them off the multichannel-crashing mpv fallback and
    /// preserves native seek + surround/Atmos. Only formats AVPlayer genuinely
    /// can't hardware-decode stay on the hybrid engine: dual-layer Dolby Vision
    /// Profile 7 (BL+EL+RPU) and HEVC Range Extensions (4:2:2 / 4:4:4 / ≥12-bit).
    /// TrueHD audio still stays on mpv either way.
    public func eligibility(
        capabilities: MediaCapabilities,
        allowAnyDecodableHEVC: Bool = false
    ) -> Eligibility {
        guard byteRangeSupported else {
            return .ineligible("Original bytes are not marked range-readable")
        }
        guard isMatroskaContainer else {
            return .ineligible("Source is not a Matroska/MKV container")
        }
        guard isHevcVideo else {
            return .ineligible("Video is not HEVC")
        }

        if allowAnyDecodableHEVC {
            // Widened gate: any AVPlayer-decodable HEVC qualifies. Only exclude the
            // formats VideoToolbox can't hardware-decode (so they'd black-screen on
            // AVPlayer even after an hvc1 re-tag) — those must stay on the hybrid
            // engine. Dolby Vision *display* capability is not required here: HDR10
            // and SDR HEVC render on AVPlayer regardless of the DoVi route.
            if normalizedDolbyVisionProfile == 7 {
                return .ineligible("Dolby Vision Profile 7 stays on the hybrid engine")
            }
            if isHevcRangeExtensions {
                return .ineligible("HEVC Range Extensions (4:2:2/4:4:4/12-bit) stay on the hybrid engine")
            }
        } else {
            // Narrow (default) gate: single-layer Dolby Vision Profile 5 / 8 only.
            guard capabilities.supportsDolbyVision else {
                return .ineligible("Current display route does not advertise Dolby Vision")
            }
            guard let profile = normalizedDolbyVisionProfile else {
                return .ineligible("Source is not identified as single-layer Dolby Vision")
            }
            guard profile == 5 || profile == 8 else {
                return .ineligible("Dolby Vision Profile \(profile) stays on the hybrid engine")
            }
        }

        guard let audioCodec = sourceMetadata.audio?.codec?.lowercased(), !audioCodec.isEmpty else {
            return .ineligible("Audio codec is missing")
        }
        if audioCodec == "truehd" || audioCodec == "mlp" {
            return .ineligible("TrueHD stays on the hybrid engine")
        }
        guard audioCodec == "ac3" || audioCodec == "eac3" || audioCodec == "ec3" else {
            return .ineligible("Audio must be AC-3 or E-AC-3")
        }
        return .eligible
    }

    public func shouldPreferLocalRemux(
        capabilities: MediaCapabilities,
        allowAnyDecodableHEVC: Bool = false
    ) -> Bool {
        if case .eligible = eligibility(
            capabilities: capabilities,
            allowAnyDecodableHEVC: allowAnyDecodableHEVC
        ) { return true }
        return false
    }

    public var isMatroskaContainer: Bool {
        let container = (sourceMetadata.container ?? "").lowercased()
        return container == "mkv" || container.contains("matroska")
    }

    public var isHevcVideo: Bool {
        let codec = (sourceMetadata.video?.codec ?? "").lowercased()
        return codec == "hevc" || codec == "h265"
    }

    /// True for HEVC **Range Extensions**: 4:2:2 / 4:4:4 chroma or ≥12-bit depth.
    /// VideoToolbox hardware decode covers Main / Main 10 (4:2:0) only, so these
    /// black-screen on AVPlayer even after an hvc1 re-tag — they must stay on the
    /// hybrid engine. Main 10 4:2:0 (the basis of HDR) is intentionally excluded:
    /// only chroma/bit-depth beyond Main 10 qualifies. Mirrors the routing-side
    /// classifier in `EngineRouter.isHevcRangeExtensions`.
    public var isHevcRangeExtensions: Bool {
        guard isHevcVideo else { return false }
        let profile = (sourceMetadata.video?.profile ?? "").lowercased()
        if profile.contains("4:2:2") || profile.contains("4:4:4")
            || profile.contains("rext") || profile.contains("range extensions") {
            return true
        }
        if let depth = sourceMetadata.video?.bitDepth { return depth >= 12 }
        return false
    }

    /// Preferred Dolby Vision profile normalization:
    ///   * explicit provider profile wins (Plex);
    ///   * Jellyfin's `DOVIWith*` tokens imply single-layer Profile 8.x;
    ///   * a bare `DOVI` token is treated as Profile 5 when no explicit profile is
    ///     exposed, which matches the single-layer token Jellyfin reports for those
    ///     files in practice.
    public var normalizedDolbyVisionProfile: Int? {
        if let explicit = sourceMetadata.video?.dolbyVisionProfile {
            return explicit
        }
        switch (sourceMetadata.video?.videoRangeType ?? "").uppercased() {
        case "DOVIWITHHDR10", "DOVIWITHHLG", "DOVIWITHSDR":
            return 8
        case "DOVI":
            return 5
        default:
            return nil
        }
    }

    // MARK: - Plozzigen (wide) eligibility

    /// Video codecs AetherEngine can handle — either via its native HLS-fMP4 →
    /// AVPlayer path (HEVC/H.264/VP9) or its software decode path (AV1/dav1d).
    private static let plozzigenVideoCodecs: Set<String> = [
        "hevc", "h265", "h264", "avc", "avc1", "vp9", "av1", "av01"
    ]

    /// Wide eligibility gate for the Plozzigen engine (AetherEngine). Unlike the
    /// narrow `eligibility()` (which requires HEVC + AC3/EAC3 only), Plozzigen
    /// accepts any video/audio combination AetherEngine can process:
    ///
    /// - **Video**: HEVC, H.264, VP9, AV1 (software decode on tvOS)
    /// - **Audio**: anything — fMP4-legal codecs (AAC, AC3, EAC3, FLAC, ALAC, MP3,
    ///   Opus) are stream-copied; incompatible ones (TrueHD, DTS) are bridged to
    ///   lossless FLAC internally.
    /// - **Container**: MKV/Matroska (the primary use case; MP4 direct-play stays native)
    ///
    /// Only excludes DV Profile 7 dual-layer (unsupported everywhere except the
    /// original mastering decoder) and non-range-readable sources (can't seek).
    public var plozzigenEligibility: Eligibility {
        guard byteRangeSupported else {
            return .ineligible("Source bytes are not range-readable")
        }
        guard isMatroskaContainer else {
            return .ineligible("Not a Matroska container (MP4/MOV direct-play stays native)")
        }
        let videoCodec = (sourceMetadata.video?.codec ?? "").lowercased()
        guard Self.plozzigenVideoCodecs.contains(videoCodec) else {
            return .ineligible("Video codec '\(videoCodec)' not supported by Plozzigen")
        }
        // DV Profile 7 (dual-layer BL+EL+RPU) can't be remuxed to single-layer.
        if normalizedDolbyVisionProfile == 7 {
            return .ineligible("Dolby Vision Profile 7 (dual-layer) requires hybrid engine")
        }
        return .eligible
    }
}
