import CoreModels
import Foundation
import MediaTransportCore
@testable import MediaTransportFTP
import XCTest

/// Pure protocol-logic coverage: reply framing, PASV/EPSV parsing, MLSD/LIST
/// dialect parsing, timestamps, and path containment — all socket-free.
final class FTPProtocolParsingTests: XCTestCase {
    // MARK: - Reply framing

    func testSingleLineReply() throws {
        var parser = FTPReplyParser()
        let reply = try parser.consume(line: "220 Service ready")
        XCTAssertEqual(reply, FTPReply(code: 220, text: "Service ready"))
    }

    func testMultiLineReply() throws {
        var parser = FTPReplyParser()
        XCTAssertNil(try parser.consume(line: "211-Features:"))
        XCTAssertNil(try parser.consume(line: " MLSD"))
        XCTAssertNil(try parser.consume(line: " REST STREAM"))
        let reply = try parser.consume(line: "211 End")
        XCTAssertEqual(reply?.code, 211)
        // Continuation lines keep their content verbatim, including the leading
        // space FEAT indents them with (the backend trims per-feature).
        XCTAssertEqual(reply?.text, "Features:\n MLSD\n REST STREAM\nEnd")
    }

    func testMultiLineReplyNotTerminatedByNumericContinuation() throws {
        // A continuation line that looks numeric but doesn't match the opening
        // code + space must NOT terminate the reply.
        var parser = FTPReplyParser()
        XCTAssertNil(try parser.consume(line: "200-first"))
        XCTAssertNil(try parser.consume(line: "200-still going"))
        // Different code with space does not terminate a 200 multiline.
        XCTAssertNil(try parser.consume(line: "226 not the opener"))
        let reply = try parser.consume(line: "200 done")
        XCTAssertEqual(reply?.code, 200)
    }

    func testMalformedReplyThrows() {
        var parser = FTPReplyParser()
        XCTAssertThrowsError(try parser.consume(line: "oops no code"))
    }

    // MARK: - Passive parsing

    func testParsePASV() throws {
        let result = try FTPPassiveParser.parsePASV("227 Entering Passive Mode (192,168,1,10,195,80).")
        XCTAssertEqual(result.advertisedIPv4, "192.168.1.10")
        XCTAssertEqual(result.port, 195 * 256 + 80)
    }

    func testParsePASVRejectsOutOfRange() {
        XCTAssertThrowsError(try FTPPassiveParser.parsePASV("227 (999,1,1,1,1,1)"))
    }

    func testParseEPSV() throws {
        let result = try FTPPassiveParser.parseEPSV("229 Entering Extended Passive Mode (|||49152|)")
        XCTAssertNil(result.advertisedIPv4)
        XCTAssertEqual(result.port, 49152)
    }

    func testParseEPSVMalformed() {
        XCTAssertThrowsError(try FTPPassiveParser.parseEPSV("229 nonsense"))
    }

    // MARK: - MLSD / LIST

    func testParseMLSD() {
        let payload = """
        type=cdir;modify=20230101120000; .
        type=pdir; ..
        type=dir;modify=20230101120000; Season 1
        type=file;size=734003200;modify=20240115093000; Episode.mkv
        type=OS.unix=slink:/x; link
        """.replacingOccurrences(of: "\n", with: "\r\n")
        let entries = FTPListParser.parseMLSD(payload)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].name, "Season 1")
        XCTAssertEqual(entries[0].kind, .directory)
        XCTAssertNil(entries[0].size)
        XCTAssertEqual(entries[1].name, "Episode.mkv")
        XCTAssertEqual(entries[1].kind, .file)
        XCTAssertEqual(entries[1].size, 734003200)
        XCTAssertNotNil(entries[1].modifiedAt)
    }

    func testParseUnixLIST() {
        let payload = """
        drwxr-xr-x  2 owner group     4096 Jan 01 12:00 Season 1
        -rw-r--r--  1 owner group 12345678 Feb 15 2024 My Movie.mkv
        lrwxrwxrwx  1 owner group        9 Jan 01 12:00 shortcut -> target
        """
        let entries = FTPListParser.parseLIST(payload)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].name, "Season 1")
        XCTAssertEqual(entries[0].kind, .directory)
        XCTAssertEqual(entries[1].name, "My Movie.mkv")
        XCTAssertEqual(entries[1].kind, .file)
        XCTAssertEqual(entries[1].size, 12345678)
    }

    func testParseDOSLIST() {
        let payload = """
        01-15-24  09:30AM       <DIR>          Season 1
        01-15-24  09:30AM             12345678 Movie.mkv
        """
        let entries = FTPListParser.parseLIST(payload)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].kind, .directory)
        XCTAssertEqual(entries[1].kind, .file)
        XCTAssertEqual(entries[1].size, 12345678)
    }

    func testParseMLSDTimestamp() {
        let date = FTPListParser.parseMLSDTimestamp("20240115093000")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date!)
        XCTAssertEqual(components.year, 2024)
        XCTAssertEqual(components.month, 1)
        XCTAssertEqual(components.day, 15)
        XCTAssertEqual(components.hour, 9)
        XCTAssertEqual(components.minute, 30)
    }

    func testParseMLSDTimestampRejectsShort() {
        XCTAssertNil(FTPListParser.parseMLSDTimestamp("2024"))
    }

    // MARK: - Path policy

    func testAbsolutePathAnchoring() throws {
        XCTAssertEqual(try FTPPathPolicy.absolutePath(root: "/media", relative: "movies/a.mkv"), "/media/movies/a.mkv")
        XCTAssertEqual(try FTPPathPolicy.absolutePath(root: "/", relative: "a.mkv"), "/a.mkv")
        XCTAssertEqual(try FTPPathPolicy.absolutePath(root: "/media", relative: ""), "/media")
    }

    func testAbsolutePathRejectsTraversal() {
        XCTAssertThrowsError(try FTPPathPolicy.absolutePath(root: "/media", relative: "../etc/passwd"))
        XCTAssertThrowsError(try FTPPathPolicy.absolutePath(root: "/media", relative: "a/../../b"))
    }

    func testChildRelativePath() throws {
        XCTAssertEqual(try FTPPathPolicy.childRelativePath(parent: "movies", name: "a.mkv"), "movies/a.mkv")
        XCTAssertEqual(try FTPPathPolicy.childRelativePath(parent: "", name: "a.mkv"), "a.mkv")
        XCTAssertThrowsError(try FTPPathPolicy.childRelativePath(parent: "movies", name: ".."))
        XCTAssertThrowsError(try FTPPathPolicy.childRelativePath(parent: "movies", name: "a/b"))
    }

    func testNormalizeRoot() throws {
        XCTAssertEqual(try FTPPathPolicy.normalizeRoot("/media/movies/"), "/media/movies")
        XCTAssertEqual(try FTPPathPolicy.normalizeRoot("//media//"), "/media")
        XCTAssertEqual(try FTPPathPolicy.normalizeRoot("/"), "/")
    }
}
