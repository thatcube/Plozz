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
    public static let defaultID = referenceServerRemuxID

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

    public static let builtInChoices: [LocalRemuxStrategyChoice] = [
        .disabled,
        .referenceServerRemux
    ]

    /// Thread-safe holder for strategy choices contributed at launch by engine
    /// modules (e.g. the cue-driven localhost-HLS remux in EngineMPV). Keeping the
    /// *choice* registry in CoreModels — separate from FeaturePlayback's *factory*
    /// registry — lets persistence (`PlaybackPreferencesStore`) and display-name
    /// resolution (`choice(for:)`) recognise dynamic ids everywhere, without
    /// CoreModels needing to know how to build a streamer.
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

    /// The dynamically-contributed choices only (no built-ins).
    public static var dynamicChoices: [LocalRemuxStrategyChoice] {
        DynamicChoiceRegistry.shared.all
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
    /// over the raw-MKV mpv path: single-layer Dolby Vision Profile 5 / 8.x in an
    /// MKV/Matroska container, Apple-decodable HEVC video, and AC-3 / E-AC-3 audio
    /// (including DD+ JOC Atmos). Profile 7 / TrueHD remain on the hybrid engine.
    public func eligibility(capabilities: MediaCapabilities) -> Eligibility {
        guard byteRangeSupported else {
            return .ineligible("Original bytes are not marked range-readable")
        }
        guard capabilities.supportsDolbyVision else {
            return .ineligible("Current display route does not advertise Dolby Vision")
        }
        guard isMatroskaContainer else {
            return .ineligible("Source is not a Matroska/MKV container")
        }
        guard isHevcVideo else {
            return .ineligible("Video is not HEVC")
        }
        guard let profile = normalizedDolbyVisionProfile else {
            return .ineligible("Source is not identified as single-layer Dolby Vision")
        }
        guard profile == 5 || profile == 8 else {
            return .ineligible("Dolby Vision Profile \(profile) stays on the hybrid engine")
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

    public func shouldPreferLocalRemux(capabilities: MediaCapabilities) -> Bool {
        if case .eligible = eligibility(capabilities: capabilities) { return true }
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
}
