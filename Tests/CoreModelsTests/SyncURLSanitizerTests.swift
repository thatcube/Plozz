import XCTest
@testable import CoreModels

final class SyncURLSanitizerTests: XCTestCase {

    func testStripsJellyfinApiKeyQuery() {
        let url = URL(string: "https://media.example.com/Users/abc/Images/Primary?tag=xyz&api_key=SECRETTOKEN")!
        let cleaned = SyncURLSanitizer.sanitize(url)
        XCTAssertFalse(cleaned.absoluteString.contains("SECRETTOKEN"))
        XCTAssertFalse(cleaned.absoluteString.lowercased().contains("api_key"))
        // Non-sensitive query + path/host preserved.
        XCTAssertTrue(cleaned.absoluteString.contains("tag=xyz"))
        XCTAssertEqual(cleaned.host, "media.example.com")
        XCTAssertEqual(cleaned.path, "/Users/abc/Images/Primary")
    }

    func testStripsPlexAndEmbyTokens() {
        for key in ["X-Plex-Token", "X-Emby-Token", "X-MediaBrowser-Token", "access_token", "token"] {
            let url = URL(string: "https://s.example.com/img?\(key)=T0K3N&keep=1")!
            let cleaned = SyncURLSanitizer.sanitize(url)
            XCTAssertFalse(cleaned.absoluteString.contains("T0K3N"), "\(key) not stripped")
            XCTAssertTrue(cleaned.absoluteString.contains("keep=1"))
        }
    }

    func testStripsPlexTokenFromNestedTranscoderURL() throws {
        var components = URLComponents(
            string: "https://plex.example.com/photo/:/transcode"
        )!
        components.queryItems = [
            URLQueryItem(name: "width", value: "500"),
            URLQueryItem(
                name: "url",
                value:
                    "/library/metadata/4407/thumb"
                    + "?X-Plex-Token=NESTED-SECRET"
            ),
            URLQueryItem(name: "X-Plex-Token", value: "OUTER-SECRET")
        ]
        let cleaned = SyncURLSanitizer.sanitize(try XCTUnwrap(components.url))
        let text = cleaned.absoluteString

        XCTAssertFalse(text.contains("NESTED-SECRET"))
        XCTAssertFalse(text.contains("OUTER-SECRET"))
        XCTAssertFalse(text.lowercased().contains("x-plex-token"))
        XCTAssertTrue(text.contains("width=500"))

        let cleanedComponents = try XCTUnwrap(
            URLComponents(url: cleaned, resolvingAgainstBaseURL: false)
        )
        XCTAssertEqual(
            cleanedComponents.queryItems?
                .first(where: { $0.name == "url" })?.value,
            "/library/metadata/4407/thumb"
        )
        XCTAssertTrue(SyncURLSanitizer.containsCredential(components.url!))
        XCTAssertEqual(SyncURLSanitizer.sanitize(cleaned), cleaned)
    }

    func testStripsUserInfoCredentials() {
        let url = URL(string: "https://user:password@example.com/path")!
        let cleaned = SyncURLSanitizer.sanitize(url)
        XCTAssertNil(URLComponents(url: cleaned, resolvingAgainstBaseURL: false)?.user)
        XCTAssertNil(URLComponents(url: cleaned, resolvingAgainstBaseURL: false)?.password)
        XCTAssertFalse(cleaned.absoluteString.contains("password"))
    }

    func testIdempotent() {
        let url = URL(string: "https://s.example.com/img?api_key=SECRET&tag=1")!
        let once = SyncURLSanitizer.sanitize(url)
        let twice = SyncURLSanitizer.sanitize(once)
        XCTAssertEqual(once, twice)
    }

    func testCleanURLUnchanged() {
        let url = URL(string: "https://s.example.com/img?tag=1")!
        XCTAssertEqual(SyncURLSanitizer.sanitize(url), url)
        XCTAssertFalse(SyncURLSanitizer.containsCredential(url))
    }

    func testAllQueryStrippedProducesNoQuery() {
        let url = URL(string: "https://s.example.com/img?api_key=SECRET")!
        let cleaned = SyncURLSanitizer.sanitize(url)
        XCTAssertNil(URLComponents(url: cleaned, resolvingAgainstBaseURL: false)?.query)
    }

    func testStringConvenienceAndNilPassthrough() {
        XCTAssertNil(SyncURLSanitizer.sanitize(string: nil))
        XCTAssertEqual(SyncURLSanitizer.sanitize(string: ""), "")
        let cleaned = SyncURLSanitizer.sanitize(string: "https://s.example.com/i?api_key=S")
        XCTAssertFalse(cleaned!.contains("api_key"))
        // A non-decomposable string is returned unchanged.
        XCTAssertEqual(SyncURLSanitizer.sanitize(string: "not a url"), "not a url")
    }

    func testCaseInsensitiveKeyMatch() {
        let url = URL(string: "https://s.example.com/i?API_KEY=SECRET&Api_Key=SECRET2")!
        let cleaned = SyncURLSanitizer.sanitize(url)
        XCTAssertFalse(cleaned.absoluteString.contains("SECRET"))
    }

    func testMediaItemSanitizesPersonAndArtworkSelectionURLs() throws {
        let person = MediaPerson(
            id: "person",
            name: "Person",
            imageURL: URL(
                string: "https://server/people/1?X-Plex-Token=PERSON"
            )
        )
        let item = MediaItem(
            id: "item",
            title: "Title",
            kind: .movie,
            people: [person],
            artworkSelections: [
                ArtworkSelection(
                    placement: .poster,
                    references: [
                        .remote(URL(
                            string:
                                "https://server/poster"
                                + "?X-Plex-Token=ART"
                        )!)
                    ]
                )
            ]
        )

        let clean = item.sanitizingArtworkCredentials()
        XCTAssertFalse(
            try XCTUnwrap(clean.people.first?.imageURL)
                .absoluteString.contains("PERSON")
        )
        let reference = try XCTUnwrap(
            clean.artworkSelections.first?.references.first
        )
        guard case .remote(let url) = reference else {
            return XCTFail("Expected remote artwork")
        }
        XCTAssertFalse(url.absoluteString.contains("ART"))
    }
}
