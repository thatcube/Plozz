import Foundation
import CoreModels
import AetherEngine
import AetherEngineSMB

/// Probes an SMB file's headers for real stream facts, via AetherEngine's demuxer
/// over the SMB byte reader (AVPlayer can't open smb://). Runs entirely OFF the main
/// actor. Injected into ShareProvider so ProviderShare stays engine-agnostic.
///
/// NOTE: this uses AetherEngine's standard `probe(source:)`, which currently opens
/// with the engine's default demux budget (not the bounded browse budget) — the
/// on-device timing measurement will tell us whether that resolves fast enough over
/// SMB for the common (well-formed) case, or whether we need a bounded/header-only
/// fast path (plan Phase 2).
public struct PlozzigenSMBStreamProber: SMBStreamProbing {
    /// A dedicated serial queue for the BLOCKING find_stream_info call, so it never
    /// occupies a Swift concurrency (cooperative) thread — a blocked cooperative
    /// thread starves all other async work (image loading, enrichment, UI). Serial,
    /// so it also can't run two blocking probes at once.
    private static let probeQueue = DispatchQueue(label: "com.thatcube.Plozz.smb-stream-probe", qos: .utility)

    public init() {}

    public func probe(smbURL: URL) async -> ProbedStreamFacts? {
        guard let parsed = try? SMBURL.parse(smbURL.absoluteString) else { return nil }

        let connection: SMBConnection
        do {
            connection = try await SMBConnection.connect(
                server: parsed.server,
                share: parsed.share,
                path: parsed.path,
                user: parsed.user,
                password: parsed.password
            )
        } catch {
            return nil
        }
        // We own the connection here so we can close it deterministically after the
        // probe; the reader must NOT also try to close it (ownsSource: false).
        defer { connection.close() }

        let source = MediaSource.custom(
            SMBIOReader(source: connection, ownsSource: false),
            formatHint: Self.formatHint(for: parsed.path)
        )

        // find_stream_info is a BLOCKING call; run it on a dedicated serial thread so
        // it never occupies (and exhausts) the Swift concurrency pool.
        let probe: SourceProbe? = await withCheckedContinuation { continuation in
            Self.probeQueue.async {
                continuation.resume(returning: try? AetherEngine.probe(source: source))
            }
        }

        guard let probe else { return nil }
        return Self.facts(from: probe)
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
