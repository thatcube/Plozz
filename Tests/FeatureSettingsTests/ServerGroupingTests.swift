#if canImport(SwiftUI)
import Foundation
import CoreModels
@testable import FeatureSettings
import XCTest

final class ServerGroupingTests: XCTestCase {
    private func account(id: String, url: String, provider: ProviderKind, user: String = "guest") -> Account {
        Account(
            id: id,
            server: MediaServer(id: id, name: id, baseURL: URL(string: url)!, provider: provider),
            userID: user,
            userName: user,
            deviceID: "device"
        )
    }

    /// The regression: an SMB share and a WebDAV share on the SAME NAS host used
    /// to collapse into one Settings server group (keyed by provider|host), so
    /// the second share vanished from Settings even though it worked on Home.
    /// They must now be two distinct servers.
    func testSMBAndWebDAVOnSameHostAreDistinctServers() {
        let smb = account(id: "share:192.168.68.71/media#guest",
                          url: "smb://192.168.68.71/Media", provider: .mediaShare)
        let dav = account(id: "webdav:http://192.168.68.71:8384/",
                          url: "http://192.168.68.71:8384/", provider: .mediaShare)

        let groups = serverGroups(from: [smb, dav])
        XCTAssertEqual(groups.count, 2, "SMB and WebDAV shares on one host must be separate server rows")
        XCTAssertNotEqual(serverKey(for: smb), serverKey(for: dav))
    }

    /// Two WebDAV shares on different ports of the same host are different servers.
    func testTwoWebDAVSharesDifferentPortsAreDistinct() {
        let a = account(id: "a", url: "http://192.168.68.71:8384/", provider: .mediaShare)
        let b = account(id: "b", url: "http://192.168.68.71:9000/", provider: .mediaShare)
        XCTAssertNotEqual(serverKey(for: a), serverKey(for: b))
        XCTAssertEqual(serverGroups(from: [a, b]).count, 2)
    }

    /// Two users of the SAME share still group under one server row (username is
    /// intentionally excluded from the share key), mirroring multiple profiles on
    /// one media server.
    func testTwoUsersOfSameShareGroupTogether() {
        let brandon = account(id: "share#brandon", url: "smb://192.168.68.71/Media",
                              provider: .mediaShare, user: "brandon")
        let sister = account(id: "share#sister", url: "smb://192.168.68.71/Media",
                             provider: .mediaShare, user: "sister")
        let groups = serverGroups(from: [brandon, sister])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.accounts.count, 2)
    }

    /// A media share and a media server on the same host stay distinct (different
    /// providers were already distinguished; confirm the share special-case
    /// didn't regress that).
    func testMediaServerAndShareOnSameHostStayDistinct() {
        let jelly = account(id: "j", url: "https://192.168.68.71:8096", provider: .jellyfin)
        let dav = account(id: "d", url: "http://192.168.68.71:8384/", provider: .mediaShare)
        XCTAssertNotEqual(serverKey(for: jelly), serverKey(for: dav))
        XCTAssertEqual(serverGroups(from: [jelly, dav]).count, 2)
    }
}
#endif
