import Foundation
import AetherEngine

enum PlozzigenStreamProbeExecutor {
    /// Lightweight header probes stay independent from the more expensive
    /// one-frame Atmos decoder so neither enrichment class head-of-line blocks
    /// the other.
    private static let headerQueue = DispatchQueue(
        label: "com.thatcube.Plozz.stream-probe.header",
        qos: .utility
    )
    private static let atmosQueue = DispatchQueue(
        label: "com.thatcube.Plozz.stream-probe.atmos",
        qos: .utility
    )

    static func runHeaderProbe(
        _ operation: @escaping @Sendable () -> SourceProbe?
    ) async -> SourceProbe? {
        await withCheckedContinuation { continuation in
            headerQueue.async {
                continuation.resume(returning: operation())
            }
        }
    }

    static func runAtmosProbe(
        _ operation: @escaping @Sendable () -> SourceProbe?
    ) async -> SourceProbe? {
        await withCheckedContinuation { continuation in
            atmosQueue.async {
                continuation.resume(returning: operation())
            }
        }
    }
}
