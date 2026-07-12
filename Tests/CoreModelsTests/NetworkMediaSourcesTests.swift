import XCTest
@testable import CoreModels

final class NetworkMediaSourcesTests: XCTestCase {
    private let revision = CredentialRevision(
        rawValue: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    )

    func testEndpointNormalizesHostIPv6AndRoot() throws {
        let endpoint = try MediaShareEndpoint(
            transport: .smb,
            host: " [FE80::1] ",
            port: 445,
            rootPath: "//Media/Movies/",
            options: .smb(SMBTransportOptions(requiresSigning: true))
        )

        XCTAssertEqual(endpoint.host, "fe80::1")
        XCTAssertEqual(endpoint.rootPath, "/Media/Movies")
        XCTAssertEqual(endpoint.port, 445)
    }

    func testEndpointRejectsCredentialShapedHostAndMismatchedOptions() {
        XCTAssertThrowsError(
            try MediaShareEndpoint(
                transport: .smb,
                host: "user:password@server",
                options: .smb(SMBTransportOptions())
            )
        ) { error in
            XCTAssertEqual(error as? MediaSourceModelError, .invalidHost)
        }

        XCTAssertThrowsError(
            try MediaShareEndpoint(
                transport: .sftp,
                host: "server",
                options: .webDAV(WebDAVTransportOptions())
            )
        ) { error in
            XCTAssertEqual(error as? MediaSourceModelError, .transportOptionsMismatch)
        }
    }

    func testEndpointRejectsRootTraversalIncludingEncodedTraversal() {
        for path in ["/Media/../Secrets", "/Media/%2e%2e/Secrets", "/Media/%2Fetc"] {
            XCTAssertThrowsError(
                try MediaShareEndpoint(
                    transport: .webDAV,
                    host: "server",
                    rootPath: path,
                    options: .webDAV(WebDAVTransportOptions())
                ),
                "Expected rejection for \(path)"
            )
        }
    }

    func testSecretFreeURLAcceptsOrdinaryPublicQuery() throws {
        let source = try SecretFreeURLSource(
            url: XCTUnwrap(URL(string: "https://media.example/trailer.m3u8?quality=1080"))
        )

        XCTAssertTrue(PlaybackSource.publicURL(source).isManifestStream)
        XCTAssertEqual(PlaybackSource.publicURL(source).publicURL, source.url)
        XCTAssertFalse(source.description.contains("quality"))
    }

    func testSecretFreeURLRejectsCredentialsAndSignedQueries() throws {
        let rejected = [
            "https://user:password@media.example/movie.mp4",
            "https://media.example/movie.mp4?X-Plex-Token=secret",
            "https://media.example/movie.mp4?X-Amz-Signature=secret",
            "https://media.example/movie.mp4?access_token=secret",
            "https://media.example/movie.mp4?expire=9999999999&sig=secret",
            "https://media.example:65536/movie.mp4",
            "https://media.example/movie.mp4#token=secret"
        ]

        for value in rejected {
            XCTAssertThrowsError(
                try SecretFreeURLSource(url: XCTUnwrap(URL(string: value))),
                "Expected rejection for \(value)"
            )
        }
    }

    func testRepresentationRequiresStrongETagAndNonnegativeSize() throws {
        XCTAssertThrowsError(
            try RemoteFileIdentity(kind: .strongETag, value: "W/\"weak\"")
        ) { error in
            XCTAssertEqual(
                error as? MediaSourceModelError,
                .invalidRepresentationIdentity
            )
        }

        let identity = try RemoteFileIdentity(kind: .strongETag, value: "\"strong\"")
        XCTAssertThrowsError(
            try RemoteFileRepresentation(
                size: -1,
                identity: identity,
                consistency: .stronglyBound
            )
        ) { error in
            XCTAssertEqual(error as? MediaSourceModelError, .invalidFileSize)
        }
    }

    func testNetworkLocatorNormalizesRelativePathAndRejectsTraversal() throws {
        let identity = try RemoteFileIdentity(kind: .strongETag, value: "\"strong\"")
        let representation = try RemoteFileRepresentation(
            size: 100,
            identity: identity,
            consistency: .stronglyBound
        )
        let locator = try NetworkFileLocator(
            accountID: "account",
            sourceID: "source",
            credentialRevision: revision,
            relativePath: "Movies//Film.mkv",
            representation: representation,
            formatHint: MediaFormatHint(container: ".MKV", mimeType: " VIDEO/X-MATROSKA ")
        )

        XCTAssertEqual(locator.relativePath, "Movies/Film.mkv")
        XCTAssertEqual(locator.formatHint.container, "mkv")
        XCTAssertEqual(locator.formatHint.mimeType, "video/x-matroska")
        XCTAssertFalse(PlaybackSource.networkFile(locator).isManifestStream)

        XCTAssertThrowsError(
            try NetworkFileLocator(
                accountID: "account",
                sourceID: "source",
                credentialRevision: revision,
                relativePath: "Movies/%2E%2E/Secrets/file.mkv",
                representation: representation
            )
        ) { error in
            XCTAssertEqual(error as? MediaSourceModelError, .invalidRelativePath)
        }
    }

    func testAuthenticatedHTTPLocatorCarriesIdentityWithoutResolvedURL() throws {
        let locator = try AuthenticatedHTTPPlaybackLocator(
            provider: .jellyfin,
            accountID: "account",
            credentialRevision: revision,
            itemID: "item",
            mediaSourceID: "source",
            deliveryMode: .serverTranscode,
            formatHint: MediaFormatHint(container: "ts")
        )
        let source = PlaybackSource.authenticatedHTTP(locator)

        XCTAssertTrue(source.isManifestStream)
        XCTAssertNil(source.publicURL)
        XCTAssertFalse(source.redactedLabel.contains("token"))
    }

    func testAuthenticatedHTTPLocatorRejectsMediaShareProvider() {
        XCTAssertThrowsError(
            try AuthenticatedHTTPPlaybackLocator(
                provider: .mediaShare,
                accountID: "account",
                credentialRevision: revision,
                itemID: "item",
                deliveryMode: .directFile
            )
        ) { error in
            XCTAssertEqual(
                error as? MediaSourceModelError,
                .unsupportedProvider(.mediaShare)
            )
        }
    }

    func testDLNALocatorPreservesAuthorityAndDeliverySemantics() throws {
        let origin = try NetworkOrigin(
            url: XCTUnwrap(URL(string: "http://192.168.1.20:8200"))
        )
        let locator = try DLNAResourceLocator(
            sourceID: "source",
            deviceUDN: "uuid:device",
            objectID: "object",
            resourceID: "resource",
            acceptedOrigin: origin,
            authorityGrantRevision: AuthorityGrantRevision(),
            deliveryMode: .linear
        )
        let source = PlaybackSource.dlnaResource(locator)

        XCTAssertEqual(origin.port, 8200)
        XCTAssertFalse(locator.deliveryMode.isSeekable)
        XCTAssertFalse(source.isManifestStream)
        XCTAssertNil(source.publicURL)
    }

    func testNetworkOriginRejectsPathQueryAndCredentials() throws {
        for value in [
            "http://user:password@host:8200",
            "http://host:8200?token=secret",
            "http://host:8200/content/item",
            "ftp://host:21"
        ] {
            XCTAssertThrowsError(
                try NetworkOrigin(url: XCTUnwrap(URL(string: value))),
                "Expected rejection for \(value)"
            )
        }
    }
}
