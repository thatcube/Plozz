import XCTest
@testable import CoreModels

final class DiagnosticsReportTests: XCTestCase {
    func testNewIssueURLContainsEnvironmentAndRedactedLogTail() throws {
        let report = DiagnosticsReport(
            appVersion: "1.2",
            appBuild: "34",
            providers: "Jellyfin, Plex",
            repoURL: "https://github.com/thatcube/Plozz/",
            recentLogTail: "safe recent activity"
        )

        let url = try XCTUnwrap(report.newIssueURL)
        let components = try XCTUnwrap(
            URLComponents(url: url, resolvingAgainstBaseURL: false)
        )
        let values = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
                item.value.map { (item.name, $0) }
            }
        )

        XCTAssertEqual(url.path, "/thatcube/Plozz/issues/new")
        XCTAssertEqual(values["labels"], "bug")
        XCTAssertEqual(values["title"], "[Bug] ")
        XCTAssertTrue(values["body"]?.contains("Plozz: 1.2 (build 34)") == true)
        XCTAssertTrue(values["body"]?.contains("Provider(s): Jellyfin, Plex") == true)
        XCTAssertTrue(values["body"]?.contains("safe recent activity") == true)
    }

    func testRecentLogTailIsBounded() {
        let report = DiagnosticsReport(
            appVersion: "1",
            appBuild: "1",
            providers: "None",
            repoURL: "https://github.com/thatcube/Plozz",
            recentLogTail: String(repeating: "x", count: 500)
        )

        XCTAssertEqual(report.recentLogTail.count, 401)
        XCTAssertTrue(report.recentLogTail.hasPrefix("…"))
    }
}
