import XCTest
import CoreModels
@testable import SearchIndexKit

final class SearchCatalogIndexerTests: XCTestCase {
    private struct Cursor: Codable {
        let offset: Int
    }

    private actor FakeCatalogProvider: SearchCatalogProviding {
        let records: [SearchCatalogRecord]
        let failAtOffset: Int?
        private(set) var requestedOffsets: [Int] = []

        init(records: [SearchCatalogRecord], failAtOffset: Int? = nil) {
            self.records = records
            self.failAtOffset = failAtOffset
        }

        func searchCatalogPage(
            _ request: SearchCatalogPageRequest
        ) async throws -> SearchCatalogPage {
            let offset = request.cursor.flatMap {
                try? JSONDecoder().decode(Cursor.self, from: $0).offset
            } ?? 0
            requestedOffsets.append(offset)
            if offset == failAtOffset {
                throw AppError.serverUnreachable
            }
            let end = min(offset + request.limit, records.count)
            let pageRecords = offset < end ? Array(records[offset..<end]) : []
            let next = end < records.count
                ? try JSONEncoder().encode(Cursor(offset: end))
                : nil
            return SearchCatalogPage(
                records: pageRecords,
                nextCursor: next,
                totalCount: records.count
            )
        }
    }

    private struct FakeEmbeddingProvider: SentenceEmbeddingProviding {
        let descriptor = EmbeddingModelDescriptor(
            language: .english,
            revision: 1,
            dimension: 3
        )

        func descriptor(for language: EmbeddingLanguage) async
            -> EmbeddingModelDescriptor? {
            language == .english ? descriptor : nil
        }

        func vector(
            for text: String,
            using descriptor: EmbeddingModelDescriptor
        ) async -> [Float]? {
            text.contains("restaurant") ? [1, 0, 0] : [0, 1, 0]
        }
    }

    private struct EnglishDetector: SearchLanguageDetecting {
        func hypotheses(for text: String, maximumCount: Int) async
            -> [EmbeddingLanguage] {
            maximumCount > 0 ? [.english] : []
        }
    }

    private actor CountingAdmission: SearchIndexResourceAdmitting {
        private(set) var calls = 0
        func waitForSearchIndexing() async throws {
            calls += 1
            try Task.checkCancellation()
        }
    }

    private func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("catalog-indexer-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func record(_ id: String, overview: String) -> SearchCatalogRecord {
        SearchCatalogRecord(item: MediaItem(
            id: id,
            title: "Episode \(id)",
            kind: .episode,
            overview: overview,
            parentTitle: "Example Show",
            seasonNumber: 1,
            episodeNumber: Int(id),
            libraryID: "shows"
        ))
    }

    func testPagesEmbedsBatchesAndSafelyPrunesNextGeneration() async throws {
        let directory = try tempDirectory()
        let store = LocalSearchIndex(scopeKey: "profile", directory: directory)
        let token = await store.activateWriteGeneration()
        let admission = CountingAdmission()
        let scope = SearchScanScope(
            accountID: "account",
            providerUserKey: "user",
            libraryID: "shows",
            kind: .episode
        )
        let firstProvider = FakeCatalogProvider(records: [
            record("1", overview: "Friends wait at a restaurant."),
            record("2", overview: "A crew repairs a spaceship."),
            record("3", overview: "A storm reaches the coast.")
        ])
        let firstIndexer = SearchCatalogIndexer(
            provider: firstProvider,
            index: store,
            embeddingProvider: FakeEmbeddingProvider(),
            languageDetector: EnglishDetector(),
            admission: admission,
            policy: SearchCatalogIndexingPolicy(pageSize: 2, embeddingSliceSize: 1)
        )
        let first = try await firstIndexer.index(scope: scope, writeToken: token)
        XCTAssertEqual(first, SearchCatalogIndexingResult(
            indexedDocuments: 3,
            embeddedDocuments: 3,
            pages: 2
        ))
        let firstCount = try await store.documentCount()
        let admissionCalls = await admission.calls
        XCTAssertEqual(firstCount, 3)
        XCTAssertGreaterThanOrEqual(admissionCalls, 5)

        let secondProvider = FakeCatalogProvider(records: [
            record("1", overview: "Friends wait at a restaurant.")
        ])
        let secondIndexer = SearchCatalogIndexer(
            provider: secondProvider,
            index: store,
            embeddingProvider: FakeEmbeddingProvider(),
            languageDetector: EnglishDetector(),
            policy: SearchCatalogIndexingPolicy(pageSize: 2, embeddingSliceSize: 1)
        )
        let second = try await secondIndexer.index(scope: scope, writeToken: token)
        XCTAssertEqual(second.embeddedDocuments, 0)
        let secondCount = try await store.documentCount()
        XCTAssertEqual(secondCount, 1)
    }

    func testFailurePersistsCursorAndNextRunResumes() async throws {
        let store = LocalSearchIndex(scopeKey: "profile", directory: try tempDirectory())
        let token = await store.activateWriteGeneration()
        let scope = SearchScanScope(
            accountID: "account",
            providerUserKey: "user",
            libraryID: "shows",
            kind: .episode
        )
        let records = [
            record("1", overview: "One"),
            record("2", overview: "Two")
        ]
        let failing = FakeCatalogProvider(records: records, failAtOffset: 1)
        let failingIndexer = SearchCatalogIndexer(
            provider: failing,
            index: store,
            embeddingProvider: FakeEmbeddingProvider(),
            languageDetector: EnglishDetector(),
            policy: SearchCatalogIndexingPolicy(pageSize: 1, embeddingSliceSize: 1)
        )
        do {
            _ = try await failingIndexer.index(scope: scope, writeToken: token)
            XCTFail("Expected paging failure")
        } catch {
            XCTAssertEqual(error as? AppError, .serverUnreachable)
        }
        let checkpoint = try await store.checkpoint(for: scope)
        let offset = checkpoint?.cursor.flatMap {
            try? JSONDecoder().decode(Cursor.self, from: $0).offset
        }
        XCTAssertEqual(offset, 1)

        let resumed = FakeCatalogProvider(records: records)
        let resumedIndexer = SearchCatalogIndexer(
            provider: resumed,
            index: store,
            embeddingProvider: FakeEmbeddingProvider(),
            languageDetector: EnglishDetector(),
            policy: SearchCatalogIndexingPolicy(pageSize: 1, embeddingSliceSize: 1)
        )
        _ = try await resumedIndexer.index(scope: scope, writeToken: token)
        let resumedOffsets = await resumed.requestedOffsets
        let finalCount = try await store.documentCount()
        XCTAssertEqual(resumedOffsets.first, 1)
        XCTAssertEqual(finalCount, 2)
    }

    func testUnsupportedPartitionNeverCompletesOrPrunes() async throws {
        struct UnsupportedProvider: SearchCatalogProviding {
            func searchCatalogPage(
                _ request: SearchCatalogPageRequest
            ) async throws -> SearchCatalogPage {
                .unsupported
            }
        }
        let store = LocalSearchIndex(scopeKey: "profile", directory: try tempDirectory())
        let token = await store.activateWriteGeneration()
        let scope = SearchScanScope(
            accountID: "account",
            providerUserKey: "user",
            libraryID: "unsupported",
            kind: .video
        )
        let indexer = SearchCatalogIndexer(
            provider: UnsupportedProvider(),
            index: store,
            embeddingProvider: FakeEmbeddingProvider(),
            languageDetector: EnglishDetector()
        )
        do {
            _ = try await indexer.index(scope: scope, writeToken: token)
            XCTFail("Expected unsupported partition")
        } catch {
            XCTAssertEqual(
                error as? SearchCatalogIndexingError,
                .unsupportedPartition
            )
        }
        let checkpoint = try await store.checkpoint(for: scope)
        XCTAssertNil(checkpoint)
    }
}
