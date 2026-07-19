import CoreModels
import XCTest
@testable import MediaDownloads

final class DurableDownloadedMediaStoreTests: XCTestCase {

    private func makeState(recordCount: Int) throws -> DownloadedMediaRegistryState {
        var records: [String: DownloadedMediaRecord] = [:]
        for index in 0..<recordCount {
            let record = try DownloadTestFactory.record(
                identity: .external(source: "imdb", value: "tt\(1_000_000 + index)"),
                status: .completed,
                bytesDownloaded: Int64(index),
                totalBytes: Int64(index + 1)
            )
            records[record.identityKey] = record
        }
        return DownloadedMediaRegistryState(records: records)
    }

    // Small payload cap forces the catalog across multiple chunks.
    private func makeStore(
        secure: MemorySecureStore,
        profileID: String = "p1"
    ) throws -> DurableDownloadedMediaStore {
        let backing = try DurableLocalStateStore(secureStore: secure, maximumPayloadBytes: 2_048)
        return try DurableDownloadedMediaStore(store: backing, profileID: profileID)
    }

    func testMultiChunkRoundTrip() throws {
        let secure = MemorySecureStore()
        let store = try makeStore(secure: secure)
        let state = try makeState(recordCount: 6)

        _ = store.load()
        try store.save(state)

        let reloaded = try makeStore(secure: secure)
        XCTAssertEqual(reloaded.load(), state)
    }

    func testProfilesAreIsolated() throws {
        let secure = MemorySecureStore()
        let a = try makeStore(secure: secure, profileID: "profA")
        let b = try makeStore(secure: secure, profileID: "profB")
        _ = a.load(); _ = b.load()

        try a.save(try makeState(recordCount: 2))
        XCTAssertEqual(b.load(), .empty)
    }

    func testConcurrentWriterHitsWriteConflict() throws {
        let secure = MemorySecureStore()
        let writerA = try makeStore(secure: secure)
        let writerB = try makeStore(secure: secure)

        _ = writerA.load()
        try writerA.save(try makeState(recordCount: 1))   // revision 1

        _ = writerB.load()                                // sees revision 1
        try writerA.save(try makeState(recordCount: 2))   // revision 2

        // writerB still believes it is at revision 1 -> stale write is rejected.
        XCTAssertThrowsError(try writerB.save(try makeState(recordCount: 3))) { error in
            XCTAssertEqual(error as? DurableLocalStateError, .writeConflict)
        }
    }

    func testDecodeFailureLatchesStoreAndBlocksOverwrite() throws {
        let secure = MemorySecureStore()
        let store = try makeStore(secure: secure)
        _ = store.load()
        try store.save(try makeState(recordCount: 6))

        // Corrupt the catalog by deleting every chunk key (keep the manifest), so a
        // fresh store can't reassemble it.
        let manifestSuffix = "." + base64URL("manifest")
        for key in secure.allKeys()
        where key.contains("localMediaDownloads") && !key.hasSuffix(manifestSuffix) {
            try secure.removeValue(for: key)
        }

        let reopened = try makeStore(secure: secure)
        // Load returns empty (never a partial) AND latches the store closed.
        XCTAssertEqual(reopened.load(), .empty)
        XCTAssertThrowsError(try reopened.save(try makeState(recordCount: 1))) { error in
            XCTAssertEqual(error as? DurableLocalStateError, .malformedPayload)
        }
    }

    private func base64URL(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
