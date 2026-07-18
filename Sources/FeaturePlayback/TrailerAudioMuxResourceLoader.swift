#if canImport(AVFoundation)
import Foundation
import AVFoundation

/// Serves the synthesized HLS playlists for ``TrailerAudioMuxComposer`` so a
/// video-only + audio-only YouTube trailer plays as one in-sync stream on the
/// native player.
///
/// Only the three `.m3u8` playlists are synthetic (served from memory here); the
/// media segments they reference are the real (https) googlevideo URLs, which
/// AVPlayer fetches directly — this loader never proxies media bytes.
///
/// `AVAssetResourceLoader` retains its delegate **weakly**, so the owner (the
/// video engine) must keep a strong reference for the lifetime of the
/// `AVPlayerItem`.
public final class TrailerAudioMuxResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    private let composer: TrailerAudioMuxComposer
    private let queue = DispatchQueue(label: "com.plozz.trailer-mux-loader")

    public init(composer: TrailerAudioMuxComposer) {
        self.composer = composer
    }

    /// Builds an `AVURLAsset` whose master playlist is fulfilled by this loader.
    /// Returns the asset; keep `self` alive alongside it.
    public func makeAsset() -> AVURLAsset {
        let asset = AVURLAsset(url: TrailerAudioMuxComposer.masterURL())
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    public func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let url = loadingRequest.request.url,
              url.scheme == TrailerAudioMuxComposer.scheme else {
            return false
        }

        switch url.lastPathComponent {
        case "master.m3u8":
            fulfil(loadingRequest, text: composer.masterPlaylist())
        case "video.m3u8":
            fulfil(loadingRequest, text: composer.videoMediaPlaylist())
        case "audio.m3u8":
            fulfil(loadingRequest, text: composer.audioMediaPlaylist())
        default:
            loadingRequest.finishLoading(with: URLError(.badURL))
        }
        return true
    }

    // MARK: Fulfilment

    private static let playlistType = "public.m3u8-playlist"

    private func fulfil(_ loadingRequest: AVAssetResourceLoadingRequest, text: String) {
        let data = Data(text.utf8)
        if let info = loadingRequest.contentInformationRequest {
            info.contentType = Self.playlistType
            info.contentLength = Int64(data.count)
            info.isByteRangeAccessSupported = false
        }
        loadingRequest.dataRequest?.respond(with: data)
        loadingRequest.finishLoading()
    }
}
#endif
