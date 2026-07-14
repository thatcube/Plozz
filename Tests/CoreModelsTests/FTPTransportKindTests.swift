import CoreModels
import XCTest

/// Wiring coverage for the new `.ftp` transport kind in the shared model.
final class FTPTransportKindTests: XCTestCase {
    func testSchemeMapping() {
        XCTAssertEqual(MediaShareTransportKind(mediaShareScheme: "ftp"), .ftp)
        XCTAssertEqual(MediaShareTransportKind(mediaShareScheme: "ftps"), .ftp)
        XCTAssertEqual(MediaShareTransportKind(mediaShareScheme: "FTP"), .ftp)
        XCTAssertNil(MediaShareTransportKind(mediaShareScheme: "gopher"))
    }

    func testBadgeLabel() {
        XCTAssertEqual(MediaShareTransportKind.ftp.badgeLabel, "FTP")
    }

    func testTransportOptionsKind() {
        XCTAssertEqual(MediaShareTransportOptions.ftp(FTPTransportOptions()).transportKind, .ftp)
        XCTAssertEqual(FTPTransportOptions().security, .explicitTLS)
        XCTAssertEqual(FTPTransportOptions(security: .plaintext).security, .plaintext)
    }

    func testFTPIsCaseIterablePeer() {
        XCTAssertTrue(MediaShareTransportKind.allCases.contains(.ftp))
    }
}
