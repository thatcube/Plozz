#if canImport(AVFoundation)
import Foundation
import AVFoundation
import CoreNetworking

/// Serves the synthesized HLS playlists and subtitle payloads for
/// ``SubtitleHLSComposer`` so direct-play video can carry selectable
/// external/text subtitles in the native player.
///
/// `AVAssetResourceLoader` only retains its delegate **weakly**, so the owner
/// (the player view model) must keep a strong reference for the lifetime of the
/// `AVPlayerItem`.
public final class SubtitleInjectingResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    private let composer: SubtitleHLSComposer
    /// Subtitle stream index → provider URL returning the subtitle text.
    private let sources: [Int: URL]
    private let session: URLSession
    private let queue = DispatchQueue(label: "com.plozz.subtitle-loader")

    public init(composer: SubtitleHLSComposer, session: URLSession = .shared) {
        self.composer = composer
        self.sources = Dictionary(uniqueKeysWithValues: composer.subtitles.map { ($0.index, $0.sourceURL) })
        self.session = session
    }

    /// Builds an `AVURLAsset` whose master playlist is fulfilled by this loader.
    /// Returns the asset; keep `self` alive alongside it.
    public func makeAsset() -> AVURLAsset {
        let asset = AVURLAsset(url: SubtitleHLSComposer.masterURL())
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    public func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let url = loadingRequest.request.url,
              url.scheme == SubtitleHLSComposer.scheme else {
            return false
        }
        let name = url.lastPathComponent

        switch route(for: name) {
        case .master:
            fulfil(loadingRequest, text: composer.masterPlaylist(), contentType: Self.playlistType)
        case .video:
            fulfil(loadingRequest, text: composer.videoMediaPlaylist(), contentType: Self.playlistType)
        case .subtitlePlaylist(let index):
            fulfil(loadingRequest, text: composer.subtitleMediaPlaylist(index: index), contentType: Self.playlistType)
        case .subtitlePayload(let index):
            fetchSubtitle(index: index, into: loadingRequest)
        case .unknown:
            loadingRequest.finishLoading(with: URLError(.badURL))
        }
        return true
    }

    // MARK: Routing

    private enum Route {
        case master
        case video
        case subtitlePlaylist(Int)
        case subtitlePayload(Int)
        case unknown
    }

    private func route(for name: String) -> Route {
        if name == "master.m3u8" { return .master }
        if name == "video.m3u8" { return .video }
        if name.hasPrefix("sub-"), name.hasSuffix(".m3u8"),
           let index = parseIndex(name, prefix: "sub-", suffix: ".m3u8") {
            return .subtitlePlaylist(index)
        }
        if name.hasPrefix("sub-"), name.hasSuffix(".vtt"),
           let index = parseIndex(name, prefix: "sub-", suffix: ".vtt") {
            return .subtitlePayload(index)
        }
        return .unknown
    }

    private func parseIndex(_ name: String, prefix: String, suffix: String) -> Int? {
        Int(name.dropFirst(prefix.count).dropLast(suffix.count))
    }

    // MARK: Fulfilment

    private static let playlistType = "public.m3u8-playlist"
    private static let webVTTType = "org.w3.webvtt"

    private func fulfil(_ loadingRequest: AVAssetResourceLoadingRequest, text: String, contentType: String) {
        fulfil(loadingRequest, data: Data(text.utf8), contentType: contentType)
    }

    private func fulfil(_ loadingRequest: AVAssetResourceLoadingRequest, data: Data, contentType: String) {
        if let info = loadingRequest.contentInformationRequest {
            info.contentType = contentType
            info.contentLength = Int64(data.count)
            info.isByteRangeAccessSupported = false
        }
        loadingRequest.dataRequest?.respond(with: data)
        loadingRequest.finishLoading()
    }

    /// Fetches a subtitle from its provider URL and normalises it to WebVTT
    /// before handing it to the player. Failure finishes the request with an
    /// error so the picker entry simply shows nothing rather than wedging.
    private func fetchSubtitle(index: Int, into loadingRequest: AVAssetResourceLoadingRequest) {
        guard let source = sources[index] else {
            loadingRequest.finishLoading(with: URLError(.fileDoesNotExist))
            return
        }
        let task = session.dataTask(with: source) { [weak self] data, _, error in
            guard let self else { return }
            self.queue.async {
                guard !loadingRequest.isCancelled else { return }
                guard let data, error == nil, let raw = String(data: data, encoding: .utf8) else {
                    PlozzLog.playback.debug("Subtitle fetch failed (non-fatal)")
                    loadingRequest.finishLoading(with: error ?? URLError(.cannotDecodeContentData))
                    return
                }
                let vtt = WebVTTNormalizer.normalize(raw)
                self.fulfil(loadingRequest, data: Data(vtt.utf8), contentType: Self.webVTTType)
            }
        }
        task.resume()
    }
}
#endif
