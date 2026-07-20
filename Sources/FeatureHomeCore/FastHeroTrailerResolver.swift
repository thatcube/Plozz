import CoreModels
import Foundation

/// Shared fast-path trailer lookup for rotating heroes. It intentionally accepts
/// only provider-local/server extras and never invokes online YouTube extraction.
@MainActor
public enum FastHeroTrailerResolver {
    public static func resolve(
        item: MediaItem,
        identitySources: [MediaSourceRef],
        providerForAccountID: (String) -> (any MediaProvider)?,
        authenticatedHTTPResolver: any AuthenticatedHTTPResourceResolving
    ) async -> HeroTrailerSource? {
        var sources = identitySources
        if let accountID = item.sourceAccountID,
           !sources.contains(where: {
               $0.accountID == accountID && $0.itemID == item.id
           }) {
            sources.insert(
                MediaSourceRef(
                    accountID: accountID,
                    itemID: item.id,
                    kind: item.kind
                ),
                at: 0
            )
        }

        for source in sources {
            guard !Task.isCancelled,
                  let provider = providerForAccountID(source.accountID) else {
                continue
            }
            let trailers = (try? await provider.trailers(for: source.itemID)) ?? []
            guard let local = trailers.first(where: { !$0.isYouTubeTrailer }),
                  let request = try? await provider.playbackInfo(for: local.id)
            else {
                continue
            }

            let url: URL?
            if let streamURL = request.streamURL {
                url = streamURL
            } else if case .some(.authenticatedHTTP(let locator)) =
                request.playbackSource {
                url = try? await authenticatedHTTPResolver.resolve(locator)
            } else {
                url = request.playbackSource?.publicURL
            }

            if let url,
               let duration = await HeroTrailerController.resolvedDuration(of: url) {
                return HeroTrailerSource(
                    ownerItemID: item.id,
                    trailerItemID: local.id,
                    url: url,
                    duration: duration
                )
            }
        }
        return nil
    }
}
