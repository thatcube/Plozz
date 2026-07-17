import Foundation

/// Provider-neutral dynamic range carried by the media itself.
public enum SourceDynamicRange: String, Codable, Equatable, Sendable {
    case sdr
    case hlg
    case hdr10
    case hdr10Plus
    case dolbyVision

    public var isHDR: Bool { self != .sdr }

    /// Best-effort early hint from provider metadata. Missing or unrecognized
    /// metadata remains unknown rather than being mislabeled SDR.
    public static func providerHint(from metadata: MediaSourceMetadata?) -> Self? {
        guard let video = metadata?.video else { return nil }
        return classify(
            videoRangeType: video.videoRangeType,
            videoRange: video.videoRange,
            colorTransfer: video.colorTransfer,
            dolbyVisionProfile: video.dolbyVisionProfile
        )
    }

    /// Classifies normalized video signals regardless of whether they came from
    /// provider metadata or an engine-backed file-header probe.
    public static func classify(
        videoRangeType: String?,
        videoRange: String? = nil,
        colorTransfer: String? = nil,
        dolbyVisionProfile: Int? = nil
    ) -> Self? {
        let rangeType = videoRangeType?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
        let range = videoRange?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
        let transfer = colorTransfer?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""

        if dolbyVisionProfile != nil || rangeType.hasPrefix("DOVI") {
            return .dolbyVision
        }
        if rangeType.hasPrefix("HDR10PLUS") || rangeType.hasPrefix("HDR10+") {
            return .hdr10Plus
        }
        if rangeType == "HLG" || transfer == "arib-std-b67" {
            return .hlg
        }
        if rangeType.hasPrefix("HDR10") || rangeType == "HDR"
            || transfer == "smpte2084" || range == "HDR" {
            return .hdr10
        }
        if rangeType == "SDR" || range == "SDR"
            || ["bt709", "iec61966-2-1", "smpte170m"].contains(transfer) {
            return .sdr
        }
        return nil
    }
}

/// Best available playback range and the authority behind it.
public enum EffectiveDynamicRange: Equatable, Sendable {
    public enum Authority: Equatable, Sendable {
        case providerMetadata
        case engineProbe
        case nativeFallback
    }

    /// Plozzigen has not finished probing. The optional provider value is useful
    /// for early UI decisions but may still be corrected by the engine.
    case awaitingEngineProbe(hint: SourceDynamicRange?)
    case resolved(SourceDynamicRange, authority: Authority)

    public static func awaitingEngineProbe(metadata: MediaSourceMetadata?) -> Self {
        .awaitingEngineProbe(hint: SourceDynamicRange.providerHint(from: metadata))
    }

    /// Native AVPlayer has no independent demux probe in Plozz. Preserve its
    /// historical behavior by treating an absent hint as SDR.
    public static func native(metadata: MediaSourceMetadata?) -> Self {
        if let hint = SourceDynamicRange.providerHint(from: metadata) {
            return .resolved(hint, authority: .providerMetadata)
        }
        return .resolved(.sdr, authority: .nativeFallback)
    }

    public var bestAvailable: SourceDynamicRange? {
        switch self {
        case .awaitingEngineProbe(let hint):
            return hint
        case .resolved(let range, _):
            return range
        }
    }

    public var authoritativeRange: SourceDynamicRange? {
        guard case .resolved(let range, _) = self else { return nil }
        return range
    }

    public var authority: Authority? {
        guard case .resolved(_, let authority) = self else { return nil }
        return authority
    }

    public var isAwaitingEngineProbe: Bool {
        if case .awaitingEngineProbe = self { return true }
        return false
    }

    public func applyingEngineProbe(_ facts: EngineProbedSourceFacts) -> Self {
        guard let range = facts.range else { return self }
        return .resolved(range, authority: .engineProbe)
    }
}
