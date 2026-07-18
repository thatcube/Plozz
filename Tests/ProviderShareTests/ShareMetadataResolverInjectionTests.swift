import CoreModels
import Foundation
import MetadataKit
@testable import ProviderShare
import XCTest

/// Batch 10 (finding E2): the share resolvers must receive every external capability
/// explicitly and reach no process-wide metadata router internally. These tests drive
/// both resolvers with fully fake capabilities (proving the record is composed from
/// the injected fakes, so no global is consulted) and add a source-inspection gate
/// asserting the coordinator/resolvers name none of the forbidden globals.
final class ShareMetadataResolverInjectionTests: XCTestCase {

    private func request(
        title: String = "Fixture",
        isMovie: Bool = true,
        isAnime: Bool = false,
        knownTVDBID: String? = nil
    ) -> ShareEnrichRequest {
        ShareEnrichRequest(
            itemID: "item-1",
            title: title,
            year: 2001,
            isMovie: isMovie,
            isAnime: isAnime,
            knownTVDBID: knownTVDBID
        )
    }

    func testKeylessResolverComposesRecordFromInjectedCapabilities() async {
        let poster = URL(string: "https://fake.test/poster.jpg")!
        let hero = URL(string: "https://fake.test/hero.jpg")!
        let logo = URL(string: "https://fake.test/logo.png")!
        let resolver = KeylessShareResolver(
            idResolver: FakeShareExternalIDs([
                "anilist": SourcedValue(value: "999", source: .anilist)
            ]),
            artworkResolver: FakeShareArtwork { kind in
                switch kind {
                case .poster: return SourcedValue(value: poster, source: .tvmaze)
                case .hero: return SourcedValue(value: hero, source: .tvmaze)
                case .logo: return SourcedValue(value: logo, source: .tvmaze)
                default: return nil
                }
            },
            overviewResolver: FakeShareOverview(SourcedValue(value: "Fake overview.", source: .wikipedia))
        )

        let record = await resolver.resolve(request(isMovie: false, isAnime: true))

        XCTAssertEqual(record.providerIDs["anilist"], "999")
        XCTAssertEqual(record.overview, "Fake overview.")
        XCTAssertEqual(record.posterURL, poster)
        XCTAssertEqual(record.backdropURL, hero)
        XCTAssertEqual(record.logoURL, logo)
    }

    func testTVDBResolverPrefersInjectedTVDBMetadataThenFillsFromInjectedRouters() async {
        let tvdbPoster = URL(string: "https://fake.test/tvdb-poster.jpg")!
        let hero = URL(string: "https://fake.test/hero.jpg")!
        let logo = URL(string: "https://fake.test/logo.png")!
        let resolver = TVDBShareResolver(
            tvdb: FakeTVDBMetadata(
                TVDBMetadata(
                    tvdbID: "12345",
                    overview: "TVDB overview.",
                    posterURL: tvdbPoster,
                    genres: ["Drama"],
                    year: 2001,
                    title: "Canonical Title"
                )
            ),
            idResolver: FakeShareExternalIDs([
                "imdb": SourcedValue(value: "tt0001", source: .tvmaze)
            ]),
            artworkResolver: FakeShareArtwork { kind in
                switch kind {
                case .hero: return SourcedValue(value: hero, source: .tvmaze)
                case .logo: return SourcedValue(value: logo, source: .tvmaze)
                default: return nil
                }
            },
            overviewResolver: FakeShareOverview(SourcedValue(value: "Should not win.", source: .wikipedia))
        )

        let record = await resolver.resolve(request(isMovie: false, knownTVDBID: "12345"))

        // TheTVDB (injected fake) wins for poster/overview/id/title...
        XCTAssertEqual(record.providerIDs["Tvdb"], "12345")
        XCTAssertEqual(record.overview, "TVDB overview.")
        XCTAssertEqual(record.posterURL, tvdbPoster)
        XCTAssertEqual(record.title, "Canonical Title")
        // ...and the injected artwork router fills backdrop/logo TheTVDB lacks.
        XCTAssertEqual(record.backdropURL, hero)
        XCTAssertEqual(record.logoURL, logo)
    }

    func testTVDBResolverFallsBackToInjectedPosterAndOverviewWhenTVDBEmpty() async {
        let poster = URL(string: "https://fake.test/keyless-poster.jpg")!
        let resolver = TVDBShareResolver(
            tvdb: FakeTVDBMetadata(nil),
            idResolver: FakeShareExternalIDs(),
            artworkResolver: FakeShareArtwork { kind in
                kind == .poster ? SourcedValue(value: poster, source: .tvmaze) : nil
            },
            overviewResolver: FakeShareOverview(SourcedValue(value: "Keyless overview.", source: .wikipedia))
        )

        let record = await resolver.resolve(request(isMovie: false))

        XCTAssertEqual(record.posterURL, poster)
        XCTAssertEqual(record.overview, "Keyless overview.")
    }

    // MARK: - Source-inspection gate

    /// Locates a `Sources/ProviderShare/<file>` for reading, navigating up from this
    /// test file's compile-time path (…/Tests/ProviderShareTests/<this>).
    private func providerShareSource(_ file: String) throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile
            .deletingLastPathComponent() // ProviderShareTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
        let source = repoRoot
            .appendingPathComponent("Sources/ProviderShare")
            .appendingPathComponent(file)
        return try String(contentsOf: source, encoding: .utf8)
    }

    func testCoordinatorSourceNamesNoConcreteMetadataSelection() throws {
        let source = try providerShareSource("ShareCatalogCoordinator.swift")
        for forbidden in [
            "TVDBConfig.resolved()",
            "TVDBShareResolver(",
            "KeylessShareResolver(",
            "ArtworkRouter.shared",
            "OverviewRouter.shared",
            "ShareExternalResolverSelection"
        ] {
            XCTAssertFalse(
                source.contains(forbidden),
                "ShareCatalogCoordinator must not reference \(forbidden)"
            )
        }
    }

    func testResolverSourceReachesNoGlobalRouterOrClient() throws {
        let source = try providerShareSource("ShareMetadataResolver.swift")
        for forbidden in [
            "ArtworkRouter.shared",
            "OverviewRouter.shared",
            "KeylessIDResolver(",
            "TVDBClient("
        ] {
            XCTAssertFalse(
                source.contains(forbidden),
                "ShareMetadataResolver must not reference \(forbidden)"
            )
        }
    }
}
