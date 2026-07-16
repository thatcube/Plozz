import XCTest
@testable import MetadataKit

final class MetadataDiskCacheBudgetTests: XCTestCase {
    func testPersistentCachePrunesToByteBudget() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plozz-metadata-budget-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let maxBytes = 1_500
        let cache = MetadataDiskCache(directory: directory, maxBytes: maxBytes)
        for index in 0..<30 {
            let payload = String(repeating: "\(index)x", count: 80)
            await cache.store(
                URL(string: "https://example.com/\(index)/\(payload)")!,
                for: "key-\(index)"
            )
        }

        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        let size = files.reduce(0) { partial, file in
            partial + ((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        XCTAssertLessThanOrEqual(size, maxBytes)
    }

    func testExistingFileIsPrunedToByteBudgetWhenLoaded() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plozz-metadata-load-budget-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let writer = MetadataDiskCache(directory: directory, maxBytes: 1_000_000)
        for index in 0..<30 {
            let payload = String(repeating: "\(index)y", count: 80)
            await writer.store(
                URL(string: "https://example.com/\(index)/\(payload)")!,
                for: "legacy-\(index)"
            )
        }

        let maxBytes = 1_500
        let reader = MetadataDiskCache(directory: directory, maxBytes: maxBytes)
        _ = await reader.cached("legacy-0")
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        let size = files.reduce(0) { partial, file in
            partial + ((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        XCTAssertLessThanOrEqual(size, maxBytes)
    }
}
