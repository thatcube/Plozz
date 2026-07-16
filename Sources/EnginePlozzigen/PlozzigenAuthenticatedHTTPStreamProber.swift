import Foundation
import AetherEngine
import CoreModels

/// Authoritatively detects E-AC-3 JOC off the UI/playback critical path.
public struct PlozzigenAuthenticatedHTTPStreamProber: AuthenticatedHTTPStreamProbing {
    private let resolver: any AuthenticatedHTTPResourceResolving

    public init(resolver: any AuthenticatedHTTPResourceResolving) {
        self.resolver = resolver
    }

    public func probe(
        locator: AuthenticatedHTTPPlaybackLocator
    ) async -> ProbedStreamFacts? {
        guard locator.deliveryMode == .directFile else {
            HandoffDiagnostics.emit(
                "atmosProbe SKIP item=\(locator.itemID) reason=notDirectFile"
            )
            return nil
        }
        guard let url = try? await resolver.resolve(locator) else {
            HandoffDiagnostics.emit(
                "atmosProbe FAILED item=\(locator.itemID) stage=resolve"
            )
            return nil
        }

        let started = Date()
        let probe = await PlozzigenStreamProbeExecutor.runAtmosProbe {
            try? AetherEngine.probeDetectingAtmos(url: url)
        }
        let elapsedMs = Int(Date().timeIntervalSince(started) * 1_000)
        guard let probe else {
            HandoffDiagnostics.emit(
                "atmosProbe FAILED item=\(locator.itemID) elapsed=\(elapsedMs)ms"
            )
            return nil
        }
        let facts = PlozzigenNetworkFileStreamProber.facts(from: probe)
        HandoffDiagnostics.emit(
            "atmosProbe item=\(locator.itemID) elapsed=\(elapsedMs)ms "
                + "codec=\(facts.audioCodec ?? "-") atmos=\(facts.audioIsAtmos)"
        )
        return facts
    }
}
