import XCTest
@testable import MetadataKit

private final class RecordingMetadataCacheFileIO: MetadataDiskCache.FileIO, @unchecked Sendable {
    private let lock = NSLock()
    private var eventsStorage: [String] = []

    var events: [String] { lock.withLock { eventsStorage } }

    func removeSupersededCaches(
        in directory: URL,
        currentFileName: String,
        filePrefix: String
    ) {
        lock.withLock { eventsStorage.append("cleanup") }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }
        for file in files where file.lastPathComponent != currentFileName
            && file.lastPathComponent.hasPrefix(filePrefix)
            && file.pathExtension == "json" {
            try? FileManager.default.removeItem(at: file)
        }
    }

    func read(from url: URL) -> Data? {
        lock.withLock { eventsStorage.append("read") }
        return try? Data(contentsOf: url)
    }

    func write(_ data: Data, to url: URL) {
        lock.withLock { eventsStorage.append("write") }
        try? data.write(to: url, options: .atomic)
    }
}

private final class RecordingMetadataCacheCoding: MetadataDiskCache.Coding, @unchecked Sendable {
    private let lock = NSLock()
    private var decodeCountStorage = 0
    private var encodeCountStorage = 0

    var decodeCount: Int { lock.withLock { decodeCountStorage } }
    var encodeCount: Int { lock.withLock { encodeCountStorage } }

    func decode(_ data: Data) -> [String: MetadataDiskCache.Entry]? {
        lock.withLock { decodeCountStorage += 1 }
        return try? JSONDecoder().decode([String: MetadataDiskCache.Entry].self, from: data)
    }

    func encode(_ entries: [String: MetadataDiskCache.Entry]) -> Data? {
        lock.withLock { encodeCountStorage += 1 }
        return try? JSONEncoder().encode(entries)
    }
}

final class MetadataDiskCacheBudgetTests: XCTestCase {
    func testInjectedIOAndCodingSeamsPreserveCleanupLoadWriteOrder() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plozz-metadata-seams-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try? Data("old".utf8).write(
            to: directory.appendingPathComponent("plozz-metadata-cache-v1.json")
        )
        try? Data("{}".utf8).write(
            to: directory.appendingPathComponent("plozz-metadata-cache-v3.json")
        )
        let fileIO = RecordingMetadataCacheFileIO()
        let coding = RecordingMetadataCacheCoding()
        let cache = MetadataDiskCache(
            directory: directory,
            maxBytes: 10_000,
            fileIO: fileIO,
            coding: coding
        )

        _ = await cache.cached("missing")
        await cache.store(URL(string: "https://example.com/poster.jpg"), for: "poster")

        XCTAssertEqual(fileIO.events, ["cleanup", "read", "write"])
        XCTAssertEqual(coding.decodeCount, 1)
        XCTAssertEqual(coding.encodeCount, 1)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("plozz-metadata-cache-v1.json").path
            )
        )
    }

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
