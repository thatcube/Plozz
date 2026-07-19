import XCTest
@testable import CoreModels

final class ArtworkReferenceTests: XCTestCase {
    func testNetworkReferenceRoundTripsWithoutCredentials() throws {
        let revision = CredentialRevision()
        let representation = try RemoteFileRepresentation(
            size: 4_096,
            identity: RemoteFileIdentity(
                kind: .modificationTime,
                modifiedAt: Date(timeIntervalSince1970: 123)
            ),
            consistency: .changeDetecting
        )
        let network = try NetworkArtworkReference(
            accountID: "share-account",
            credentialRevision: revision,
            relativePath: "Movies/Example/poster.jpg",
            representation: representation,
            sourceRevision: "revision-1",
            contentType: "image/jpeg",
            dimensions: ArtworkDimensions(width: 1_000, height: 1_500)
        )
        let reference = ArtworkReference.networkFile(network)

        let decoded = try JSONDecoder().decode(
            ArtworkReference.self,
            from: JSONEncoder().encode(reference)
        )

        XCTAssertEqual(decoded, reference)
        XCTAssertEqual(try network.networkFileLocator().accountID, "share-account")
        XCTAssertEqual(try network.networkFileLocator().credentialRevision, revision)
    }

    func testMediaItemPrefersExplicitPlacementThenLegacyRemoteFallback() throws {
        let local = ArtworkReference.networkFile(
            try NetworkArtworkReference(
                accountID: "share-account",
                credentialRevision: CredentialRevision(),
                relativePath: "TV/Example/landscape.jpg",
                representation: RemoteFileRepresentation(
                    size: 100,
                    identity: RemoteFileIdentity(
                        kind: .modificationTime,
                        modifiedAt: Date(timeIntervalSince1970: 123)
                    ),
                    consistency: .changeDetecting
                ),
                sourceRevision: "revision-1"
            )
        )
        let remote = try XCTUnwrap(URL(string: "https://example.com/backdrop.jpg"))
        let item = MediaItem(
            id: "movie",
            title: "Movie",
            kind: .movie,
            heroBackdropURL: remote,
            artworkSelections: [
                ArtworkSelection(placement: .homeHero, references: [local, local])
            ]
        )

        XCTAssertEqual(
            item.artworkReferences(for: .homeHero),
            [local, .remote(remote)]
        )
        XCTAssertEqual(
            item.artworkReferences(for: .detailBackdrop),
            [.remote(remote)]
        )
    }

    func testLegacyMediaItemDecodesWithoutArtworkSelections() throws {
        let item = MediaItem(id: "legacy", title: "Legacy", kind: .movie)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any]
        )
        object.removeValue(forKey: "artworkSelections")

        let decoded = try JSONDecoder().decode(
            MediaItem.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertTrue(decoded.artworkSelections.isEmpty)
    }

    func testEpisodeThumbnailLegacyReferencesStayEpisodeScoped() throws {
        let poster = try XCTUnwrap(URL(string: "https://example.com/episode.jpg"))
        let backdrop = try XCTUnwrap(URL(string: "https://example.com/episode-backdrop.jpg"))
        let seriesArtwork = try XCTUnwrap(URL(string: "https://example.com/series.jpg"))
        let item = MediaItem(
            id: "episode",
            title: "Episode",
            kind: .episode,
            posterURL: poster,
            backdropURL: backdrop,
            fallbackArtworkURL: seriesArtwork
        )

        XCTAssertEqual(
            item.artworkReferences(for: .episodeThumbnail),
            [.remote(poster), .remote(backdrop)]
        )
    }

    func testPosterLegacyReferencesPreserveFallbackOrdering() throws {
        let poster = try XCTUnwrap(URL(string: "https://example.com/poster.jpg"))
        let seriesPoster = try XCTUnwrap(URL(string: "https://example.com/series-poster.jpg"))
        let fallback = try XCTUnwrap(URL(string: "https://example.com/fallback.jpg"))
        let item = MediaItem(
            id: "legacy-posters",
            title: "Legacy Posters",
            kind: .episode,
            posterURL: poster,
            seriesPosterURL: seriesPoster,
            fallbackArtworkURL: fallback
        )

        XCTAssertEqual(item.artworkReferences(for: .poster), [.remote(poster), .remote(fallback)])
        XCTAssertEqual(
            item.artworkReferences(for: .seriesPoster),
            [.remote(seriesPoster), .remote(poster), .remote(fallback)]
        )
    }

    func testNetworkReferencePrivacySafeIdentityExcludesPath() throws {
        let revision = CredentialRevision(
            rawValue: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000444"))
        )
        let reference = ArtworkReference.networkFile(
            try NetworkArtworkReference(
                accountID: "share-account",
                credentialRevision: revision,
                relativePath: "Private/Folder/logo.png",
                representation: RemoteFileRepresentation(
                    size: 100,
                    identity: RemoteFileIdentity(kind: .modificationTime, modifiedAt: .distantPast),
                    consistency: .changeDetecting
                ),
                sourceRevision: "opaque-revision"
            )
        )

        XCTAssertFalse(reference.privacySafeIdentity.contains("Private/Folder/logo.png"))
        XCTAssertTrue(reference.privacySafeIdentity.contains("opaque-revision"))
    }
}
