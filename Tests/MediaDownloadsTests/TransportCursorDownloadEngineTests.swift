import CoreModels
import XCTest
@testable import MediaDownloads

final class TransportCursorDownloadEngineTests: XCTestCase {

    private func makeData(_ count: Int) -> Data {
        Data((0..<count).map { UInt8($0 % 251) })
    }

    func testDownloadsWholeFile() async throws {
        let payload = makeData(300)
        let opener = FakeOpener([FakeByteReader(bytes: payload, maxChunk: 64)])
        let engine = TransportCursorDownloadEngine(opener: opener, chunkSize: 128)
        let dir = DownloadTestFactory.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appendingPathComponent("media.mkv")
        let record = try DownloadTestFactory.record()

        let total = try await engine.download(record: record, to: dest) { _, _ in }

        XCTAssertEqual(total, 300)
        XCTAssertEqual(try Data(contentsOf: dest), payload)
    }

    func testInterruptionLeavesResumablePartialThenResumesToCompletion() async throws {
        let payload = makeData(300)
        let dir = DownloadTestFactory.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appendingPathComponent("media.mkv")
        let record = try DownloadTestFactory.record()

        // First attempt: short reads that fail once offset reaches 150 -> a 150-byte
        // partial file is left on disk.
        let interrupting = FakeByteReader(bytes: payload, maxChunk: 50, failAtOffset: 150)
        let engine1 = TransportCursorDownloadEngine(
            opener: FakeOpener([interrupting]), chunkSize: 50
        )
        do {
            _ = try await engine1.download(record: record, to: dest) { _, _ in }
            XCTFail("expected the interrupted download to throw")
        } catch is CancellationError {
            // expected
        }
        let partialSize = try FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int
        XCTAssertEqual(partialSize, 150)

        // Second attempt resumes from the 150 bytes already on disk.
        let completing = FakeByteReader(bytes: payload, maxChunk: 50)
        let engine2 = TransportCursorDownloadEngine(
            opener: FakeOpener([completing]), chunkSize: 50
        )
        let total = try await engine2.download(record: record, to: dest) { _, _ in }

        XCTAssertEqual(total, 300)
        XCTAssertEqual(try Data(contentsOf: dest), payload)
    }

    func testResumeOffsetPastEOFRestartsCleanly() async throws {
        // Pre-seed a stale, oversized partial (server file shrank/changed).
        let dir = DownloadTestFactory.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appendingPathComponent("media.mkv")
        try makeData(500).write(to: dest)

        let payload = makeData(120)
        let engine = TransportCursorDownloadEngine(
            opener: FakeOpener([FakeByteReader(bytes: payload, maxChunk: 40)]),
            chunkSize: 40
        )
        let record = try DownloadTestFactory.record()

        let total = try await engine.download(record: record, to: dest) { _, _ in }
        XCTAssertEqual(total, 120)
        XCTAssertEqual(try Data(contentsOf: dest), payload)
    }

    func testMissingSourceThrowsUnsupported() async throws {
        let engine = TransportCursorDownloadEngine(opener: FakeOpener([]))
        var record = try DownloadTestFactory.record()
        record.directShareSource = nil
        let dir = DownloadTestFactory.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            _ = try await engine.download(
                record: record, to: dir.appendingPathComponent("m.mkv")
            ) { _, _ in }
            XCTFail("expected unsupportedSource")
        } catch let error as MediaDownloadError {
            XCTAssertEqual(error, .unsupportedSource)
        }
    }
}
