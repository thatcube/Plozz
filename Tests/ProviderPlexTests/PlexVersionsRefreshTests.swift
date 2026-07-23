import XCTest
import CoreModels
import CoreNetworking
@testable import ProviderPlex

/// Tests for Feature A (version mapping from Plex `Media[]`) and Feature C
/// (metadata refresh) on the Plex provider.
final class PlexVersionsRefreshTests: XCTestCase {
    private func makeSession() -> UserSession {
        UserSession(
            server: MediaServer(id: "srv", name: "Home", baseURL: URL(string: "https://plex.host:32400")!, provider: .plex),
            userID: "u1", userName: "Alice", deviceID: "d1", accessToken: "TOKEN"
        )
    }

    // MARK: - Feature A: versions from Media[]

    func testVersionsMapMultipleMediaElements() throws {
        let media = try JSONDecoder.plozz.decode([PlexMedia].self, from: Data("""
        [
          {"id":1001,"container":"mkv","videoCodec":"hevc","audioCodec":"truehd",
           "duration":7200000,"bitrate":80000,
           "width":3840,"height":2160,"audioChannels":8,
           "Part":[{"file":"/movies/Movie.Extended.mkv","size":12000000000}]},
          {"id":1002,"container":"mp4","videoCodec":"h264","audioCodec":"aac",
           "width":1920,"height":1080,"audioChannels":2,
           "Part":[{"size":3000000000}]}
        ]
        """.utf8))

        let versions = PlexProvider.versions(from: media)
        XCTAssertEqual(versions.map(\.id), ["1001", "1002"])
        XCTAssertEqual(versions[0].height, 2160)
        XCTAssertEqual(versions[0].videoCodec, "hevc")
        XCTAssertEqual(versions[0].audioLabel, "7.1")
        XCTAssertEqual(versions[0].sizeBytes, 12_000_000_000)
        XCTAssertEqual(versions[0].sizeLabel, "12 GB")
        XCTAssertEqual(versions[0].fileName, "Movie.Extended.mkv")
        XCTAssertEqual(versions[0].bitrate, 80_000_000)
        XCTAssertEqual(versions[0].duration, 7200)
        XCTAssertTrue(versions[0].isDefault)
        XCTAssertEqual(versions[1].resolutionLabel, "1080p")
        XCTAssertFalse(versions[1].isDefault)
    }

    func testVersionsSumMultipartFileSizes() throws {
        let media = try JSONDecoder.plozz.decode([PlexMedia].self, from: Data("""
        [
          {"id":1001,"Part":[{"size":4000000000},{"size":6000000000}]},
          {"id":1002,"Part":[{"size":3000000000}]}
        ]
        """.utf8))

        XCTAssertEqual(PlexProvider.versions(from: media)[0].sizeBytes, 10_000_000_000)
    }

    func testSingleMediaElementProducesNoVersions() throws {
        let media = try JSONDecoder.plozz.decode([PlexMedia].self, from: Data("""
        [{"id":1,"videoCodec":"h264","height":1080}]
        """.utf8))
        XCTAssertEqual(PlexProvider.versions(from: media), [])
        XCTAssertEqual(PlexProvider.versions(from: nil), [])
    }

    // MARK: - Feature C: metadata refresh

    func testRefreshMetadataIssuesPut() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/metadata/55/refresh", json: "{}")
        let provider = PlexProvider(session: makeSession(), http: stub)

        try await provider.refreshMetadata(itemID: "55")
        XCTAssertEqual(stub.method(forPathSuffix: "/library/metadata/55/refresh"), .put)
    }
}
