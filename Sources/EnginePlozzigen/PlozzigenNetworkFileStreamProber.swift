import Foundation
import CoreModels
import AetherEngine
import MediaTransportCore

/// Probes a network file's headers through the same transport resolver and
/// representation-bound source used by playback.
///
/// Uses AetherEngine's opt-in bounded Atmos probe. This remains detail-only in
/// production; browse scans never decode media.
public struct PlozzigenNetworkFileStreamProber: NetworkFileStreamProbing {
    private let resolver: any MediaTransportNetworkFileResolving

    public init(resolver: any MediaTransportNetworkFileResolving) {
        self.resolver = resolver
    }

    public func probe(locator: NetworkFileLocator) async -> ProbedStreamFacts? {
        guard let resolved = try? await resolver.resolve(locator) else {
            HandoffDiagnostics.emit("shareProbe FAILED stage=resolve")
            return nil
        }
        let reader = TransportIOReader(resolvedSource: resolved)
        let source = MediaSource.custom(
            reader,
            formatHint: Self.formatHint(for: locator.relativePath)
        )

        // find_stream_info is a BLOCKING call; run it on a dedicated serial thread so
        // it never occupies (and exhausts) the Swift concurrency pool.
        let started = Date()
        let probe = await PlozzigenStreamProbeExecutor.runAtmosProbe {
            try? AetherEngine.probeDetectingAtmos(source: source)
        }
        let elapsedMs = Int(Date().timeIntervalSince(started) * 1_000)
        reader.close()
        await reader.waitForFinalShutdown()

        guard let probe else {
            HandoffDiagnostics.emit("shareProbe FAILED stage=probe elapsed=\(elapsedMs)ms")
            return nil
        }
        let facts = Self.facts(from: probe)
        HandoffDiagnostics.emit(
            "shareProbe elapsed=\(elapsedMs)ms range=\(facts.videoRangeType ?? "-") "
                + "codec=\(facts.audioCodec ?? "-") atmos=\(facts.audioIsAtmos)"
        )
        return facts
    }

    static func facts(from probe: SourceProbe) -> ProbedStreamFacts {
        let range: String? = switch probe.videoFormat {
        case .sdr: "SDR"
        case .hdr10: "HDR10"
        case .hdr10Plus: "HDR10Plus"
        case .hlg: "HLG"
        case .dolbyVision: "DOVI"
        }
        let audio = probe.audioTracks.first { $0.isDefault } ?? probe.audioTracks.first
        let w = Int(probe.videoWidth)
        let h = Int(probe.videoHeight)
        return ProbedStreamFacts(
            videoWidth: w > 0 ? w : nil,
            videoHeight: h > 0 ? h : nil,
            videoRangeType: range,
            videoCodec: probe.videoCodecName,
            audioTrackID: audio?.id,
            audioCodec: audio?.codec,
            audioChannels: audio.map(\.channels).flatMap { $0 > 0 ? $0 : nil },
            audioIsAtmos: audio?.isAtmos ?? false,
            durationSeconds: probe.durationSeconds > 0 ? probe.durationSeconds : nil
        )
    }

    static func formatHint(for path: String) -> String? {
        switch (path as NSString).pathExtension.lowercased() {
        case "mkv":               return "matroska"
        case "webm":              return "webm"
        case "mp4", "m4v", "mov": return "mp4"
        case "ts", "m2ts", "mts": return "mpegts"
        case "avi":               return "avi"
        default:                  return nil
        }
    }
}
