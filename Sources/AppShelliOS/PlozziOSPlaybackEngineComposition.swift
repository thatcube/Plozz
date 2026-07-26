#if os(iOS)
import CoreModels
import EnginePlozzigen
import FeaturePlayback
import MediaTransportCore

enum PlozziOSPlaybackEngineComposition {
    @MainActor
    static func engineFactory(
        networkFileResolver: any MediaTransportNetworkFileResolving,
        authenticatedHTTPResolver: any AuthenticatedHTTPResourceResolving
    ) -> EngineFactory {
        EngineFactory(
            makeNative: {
                NativeVideoEngine(
                    style: $0,
                    authenticatedHTTPResolver: authenticatedHTTPResolver
                )
            },
            makePlozzigen: {
                PlozzigenVideoEngineFactory.makeEngine(
                    networkFileResolver: networkFileResolver,
                    authenticatedHTTPResolver: authenticatedHTTPResolver
                )
            },
            probeSourceDynamicRange: { request in
                guard case .some(.networkFile(let locator)) =
                        request.playbackSource else {
                    return nil
                }
                // A probe reads headers; it must NOT preempt a library scan the way
                // starting playback does.
                let prober = PlozzigenNetworkFileStreamProber(
                    resolver: networkFileResolver.withoutPlaybackAdmission()
                )
                guard let facts = await prober.probe(locator: locator) else {
                    return nil
                }
                return SourceDynamicRange.classify(
                    videoRangeType: facts.videoRangeType
                )
            }
        )
    }
}
#endif
