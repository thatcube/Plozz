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
}
