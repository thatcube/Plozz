#if canImport(UIKit)
import XCTest
import UIKit
import CoreModels
@testable import FeaturePlayback

@MainActor
final class ScrubPreviewLoaderTests: XCTestCase {
    override func tearDown() {
        URLSessionStubProtocol.reset()
        super.tearDown()
    }

    func testTrickplayLoaderCachesTileAcrossScrubPositions() async throws {
        let tileURL = URL(string: "https://example.test/trickplay/0.jpg")!
        URLSessionStubProtocol.setResponses(
            [.init(statusCode: 200, data: try makeTileImageData())],
            for: tileURL
        )
        let loader = TrickplayThumbnailLoader(
            manifest: TrickplayManifest(
                thumbnailWidth: 10,
                thumbnailHeight: 10,
                tileColumns: 2,
                tileRows: 1,
                thumbnailCount: 2,
                intervalMs: 10_000,
                tileURLs: [tileURL]
            ),
            session: makeSession()
        )

        let first = await loader.thumbnail(forSeconds: 0)
        XCTAssertEqual(first?.width, 10)
        XCTAssertEqual(first?.height, 10)

        let second = await loader.thumbnail(forSeconds: 12)
        XCTAssertEqual(second?.width, 10)
        XCTAssertEqual(second?.height, 10)
        XCTAssertEqual(URLSessionStubProtocol.requestCount(for: tileURL), 1)
        XCTAssertNotNil(loader.cachedThumbnail(forSeconds: 12))
    }

    func testTrickplayLoaderReturnsNilWhenFetchFails() async {
        let tileURL = URL(string: "https://example.test/trickplay/missing.jpg")!
        URLSessionStubProtocol.setResponses([.init(statusCode: 404, data: Data())], for: tileURL)
        let loader = TrickplayThumbnailLoader(
            manifest: TrickplayManifest(
                thumbnailWidth: 10,
                thumbnailHeight: 10,
                tileColumns: 1,
                tileRows: 1,
                thumbnailCount: 1,
                intervalMs: 10_000,
                tileURLs: [tileURL]
            ),
            session: makeSession()
        )

        let image = await loader.thumbnail(forSeconds: 0)
        XCTAssertNil(image)
        XCTAssertNil(loader.cachedThumbnail(forSeconds: 0))
    }

    func testPlexBIFLoaderDownloadsBlobOnceAndCachesFrames() async throws {
        let bifURL = URL(string: "https://example.test/indexes/hd")!
        URLSessionStubProtocol.setResponses(
            [.init(statusCode: 200, data: try makeBIFData(frames: [makeJPEGData(color: .red), makeJPEGData(color: .blue)]))],
            for: bifURL
        )
        let loader = PlexBIFThumbnailLoader(url: bifURL, session: makeSession())

        let first = await loader.thumbnail(forSeconds: 0)
        XCTAssertNotNil(first)
        XCTAssertNotNil(loader.cachedThumbnail(forSeconds: 0.5))
        let second = await loader.thumbnail(forSeconds: 1.2)
        XCTAssertNotNil(second)
        XCTAssertEqual(URLSessionStubProtocol.requestCount(for: bifURL), 1)
    }

    func testPlexBIFLoaderRetriesAfterInitialFailure() async throws {
        let bifURL = URL(string: "https://example.test/indexes/sd")!
        URLSessionStubProtocol.setResponses(
            [
                .init(statusCode: 404, data: Data("missing".utf8)),
                .init(statusCode: 200, data: try makeBIFData(frames: [makeJPEGData(color: .green)]))
            ],
            for: bifURL
        )
        let loader = PlexBIFThumbnailLoader(url: bifURL, session: makeSession())

        let first = await loader.thumbnail(forSeconds: 0)
        XCTAssertNil(first)
        let second = await loader.thumbnail(forSeconds: 0)
        XCTAssertNotNil(second)
        XCTAssertEqual(URLSessionStubProtocol.requestCount(for: bifURL), 2)
    }

    func testControlsModelSignalsPreviewFrameAvailability() {
        let model = PlayerControlsModel()
        XCTAssertFalse(model.hasPreviewFrame)

        model.previewImage = makeSolidCGImage(color: .white)
        XCTAssertTrue(model.hasPreviewFrame)

        model.previewImage = nil
        XCTAssertFalse(model.hasPreviewFrame)
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLSessionStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeTileImageData() throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 10))
        let image = renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
            UIColor.blue.setFill()
            context.fill(CGRect(x: 10, y: 0, width: 10, height: 10))
        }
        guard let data = image.pngData() else { throw NSError(domain: "ScrubPreviewLoaderTests", code: 1) }
        return data
    }

    private func makeJPEGData(color: UIColor) -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
        let image = renderer.image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        return image.jpegData(compressionQuality: 0.9) ?? Data()
    }

    private func makeSolidCGImage(color: UIColor) -> CGImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2))
        let image = renderer.image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        return image.cgImage!
    }

    private func makeBIFData(
        frameIntervalMs: UInt32 = 1_000,
        frames: [Data]
    ) throws -> Data {
        var bytes = [UInt8]()

        func appendU32(_ value: UInt32) {
            bytes.append(UInt8(value & 0xFF))
            bytes.append(UInt8((value >> 8) & 0xFF))
            bytes.append(UInt8((value >> 16) & 0xFF))
            bytes.append(UInt8((value >> 24) & 0xFF))
        }

        bytes.append(contentsOf: BIFIndex.magic)
        appendU32(0) // version
        appendU32(UInt32(frames.count))
        appendU32(frameIntervalMs)
        bytes.append(contentsOf: [UInt8](repeating: 0, count: 64 - bytes.count))

        let indexEntries = frames.count + 1
        var offsets: [UInt32] = []
        offsets.reserveCapacity(indexEntries)
        var runningOffset = UInt32(64 + indexEntries * 8)
        for frame in frames {
            offsets.append(runningOffset)
            runningOffset += UInt32(frame.count)
        }
        offsets.append(runningOffset)

        for index in 0..<frames.count {
            appendU32(UInt32(index))
            appendU32(offsets[index])
        }
        appendU32(0xFFFF_FFFF)
        appendU32(offsets[frames.count])

        for frame in frames {
            bytes.append(contentsOf: frame)
        }
        return Data(bytes)
    }
}

private struct URLStubResponse {
    let statusCode: Int
    let data: Data
}

private final class URLSessionStubProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var responses: [URL: [URLStubResponse]] = [:]
    private static var requestCounts: [URL: Int] = [:]

    static func setResponses(_ queue: [URLStubResponse], for url: URL) {
        lock.lock()
        responses[url] = queue
        lock.unlock()
    }

    static func requestCount(for url: URL) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return requestCounts[url, default: 0]
    }

    static func reset() {
        lock.lock()
        responses = [:]
        requestCounts = [:]
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        let nextResponse: URLStubResponse = {
            Self.lock.lock()
            defer { Self.lock.unlock() }
            Self.requestCounts[url, default: 0] += 1
            guard var queue = Self.responses[url], !queue.isEmpty else {
                return URLStubResponse(statusCode: 404, data: Data())
            }
            let first = queue.removeFirst()
            Self.responses[url] = queue
            return first
        }()

        let response = HTTPURLResponse(
            url: url,
            statusCode: nextResponse.statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: nextResponse.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
#endif
