import XCTest
import CoreModels
@testable import SearchIndexKit

final class LocalSearchIndexTests: XCTestCase {
    private let descriptor = EmbeddingModelDescriptor(
        language: .english,
        revision: 1,
        dimension: 3
    )

    private func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-index-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func item(
        id: String,
        title: String,
        overview: String,
        libraryID: String = "shows",
        episode: Int = 1
    ) -> MediaItem {
        MediaItem(
            id: id,
            title: title,
            kind: .episode,
            overview: overview,
            parentTitle: "Example Show",
            seasonNumber: 1,
            episodeNumber: episode,
            genres: ["Comedy"],
            libraryID: libraryID
        )
    }

    func testStaleWriteGenerationCannotMutateStore() async throws {
        let store = LocalSearchIndex(scopeKey: "profile", directory: try tempDirectory())
        let stale = await store.activateWriteGeneration()
        _ = await store.activateWriteGeneration()
        let document = SearchDocumentBuilder().document(
            for: item(id: "1", title: "One", overview: "Plot"),
            accountID: "a",
            providerUserKey: "u"
        )

        do {
            try await store.upsert(
                document: document,
                embeddings: [],
                scanGeneration: 1,
                writeToken: stale
            )
            XCTFail("Expected stale write rejection")
        } catch {
            XCTAssertEqual(error as? SearchIndexStoreError, .staleWriteGeneration)
        }
        let count = try await store.documentCount()
        XCTAssertEqual(count, 0)
    }

    func testFullScanResumesAndPrunesOnlyWhenCompleted() async throws {
        let store = LocalSearchIndex(scopeKey: "profile", directory: try tempDirectory())
        let token = await store.activateWriteGeneration()
        let scope = SearchScanScope(
            accountID: "a",
            providerUserKey: "u",
            libraryID: "shows",
            kind: .episode
        )
        let first = try await store.beginOrResumeFullScan(scope: scope, writeToken: token)

        for id in ["1", "2"] {
            let document = SearchDocumentBuilder().document(
                for: item(id: id, title: id, overview: id),
                accountID: "a",
                providerUserKey: "u"
            )
            try await store.upsert(
                document: document,
                embeddings: [],
                scanGeneration: first.generation,
                writeToken: token
            )
        }
        try await store.saveCursor(Data("page-2".utf8), checkpoint: first, writeToken: token)
        let resumed = try await store.beginOrResumeFullScan(scope: scope, writeToken: token)
        XCTAssertEqual(resumed.generation, first.generation)
        XCTAssertEqual(resumed.cursor, Data("page-2".utf8))
        try await store.finishFullScan(
            checkpoint: resumed,
            writeToken: token,
            expectedTotalCount: 2
        )

        let second = try await store.beginOrResumeFullScan(scope: scope, writeToken: token)
        let survivor = SearchDocumentBuilder().document(
            for: item(id: "1", title: "One", overview: "Updated"),
            accountID: "a",
            providerUserKey: "u"
        )
        try await store.upsert(
            document: survivor,
            embeddings: [],
            scanGeneration: second.generation,
            writeToken: token
        )
        let beforePrune = try await store.documentCount()
        XCTAssertEqual(beforePrune, 2)
        try await store.finishFullScan(
            checkpoint: second,
            writeToken: token,
            expectedTotalCount: 1
        )
        let afterPrune = try await store.documentCount()
        XCTAssertEqual(afterPrune, 1)
    }

    func testSearchRanksSemanticEpisodeAndHonorsExclusions() async throws {
        let store = LocalSearchIndex(
            scopeKey: "profile",
            directory: try tempDirectory(),
            storageFormat: .float16
        )
        let token = await store.activateWriteGeneration()
        let scope = SearchScanScope(
            accountID: "a",
            providerUserKey: "u",
            libraryID: "shows",
            kind: .episode
        )
        let checkpoint = try await store.beginOrResumeFullScan(scope: scope, writeToken: token)
        let builder = SearchDocumentBuilder()

        let restaurant = builder.document(
            for: item(
                id: "restaurant",
                title: "The Empty Table",
                overview: "Friends wait all night at a Chinese restaurant."
            ),
            accountID: "a",
            providerUserKey: "u"
        )
        let spaceship = builder.document(
            for: item(
                id: "spaceship",
                title: "Distant Stars",
                overview: "A crew repairs a damaged spaceship.",
                episode: 2
            ),
            accountID: "a",
            providerUserKey: "u"
        )
        try await store.upsert(
            document: restaurant,
            embeddings: [
                SearchDocumentEmbedding(segment: 0, descriptor: descriptor, vector: [1, 0, 0])
            ],
            scanGeneration: checkpoint.generation,
            writeToken: token
        )
        try await store.upsert(
            document: spaceship,
            embeddings: [
                SearchDocumentEmbedding(segment: 0, descriptor: descriptor, vector: [0, 1, 0])
            ],
            scanGeneration: checkpoint.generation,
            writeToken: token
        )

        let matches = try await store.search(LocalSearchRequest(
            queryText: "the episode at a Chinese restaurant",
            queryVector: [1, 0, 0],
            descriptor: descriptor,
            intent: LocalSearchIntent(kinds: [.episode]),
            limit: 10
        ))
        XCTAssertEqual(matches.first?.item.id, "restaurant")

        let excluded = try await store.search(LocalSearchRequest(
            queryText: "restaurant",
            queryVector: [1, 0, 0],
            descriptor: descriptor,
            excludedLibraryKeys: ["a:shows"],
            limit: 10
        ))
        XCTAssertTrue(excluded.isEmpty)
    }

    func testUnchangedDocumentDoesNotNeedReembedding() async throws {
        let store = LocalSearchIndex(scopeKey: "profile", directory: try tempDirectory())
        let token = await store.activateWriteGeneration()
        let document = SearchDocumentBuilder().document(
            for: item(id: "1", title: "One", overview: "Plot"),
            accountID: "a",
            providerUserKey: "u"
        )
        try await store.upsert(
            document: document,
            embeddings: [
                SearchDocumentEmbedding(segment: 0, descriptor: descriptor, vector: [1, 0, 0])
            ],
            scanGeneration: 1,
            writeToken: token
        )
        let needsEmbedding = try await store.needsEmbedding(
            document: document,
            descriptor: descriptor
        )
        XCTAssertFalse(needsEmbedding)
    }

    func testDifferentLanguageOrRevisionNeedsEmbeddingAndDoesNotMatch() async throws {
        let store = LocalSearchIndex(scopeKey: "profile", directory: try tempDirectory())
        let token = await store.activateWriteGeneration()
        let document = SearchDocumentBuilder().document(
            for: item(id: "1", title: "One", overview: "Plot"),
            accountID: "a",
            providerUserKey: "u"
        )
        try await store.upsert(
            document: document,
            embeddings: [
                SearchDocumentEmbedding(segment: 0, descriptor: descriptor, vector: [1, 0, 0])
            ],
            scanGeneration: 1,
            writeToken: token
        )

        let spanish = EmbeddingModelDescriptor(
            language: .spanish,
            revision: descriptor.revision,
            dimension: descriptor.dimension
        )
        let newerEnglish = EmbeddingModelDescriptor(
            language: .english,
            revision: descriptor.revision + 1,
            dimension: descriptor.dimension
        )
        let needsSpanish = try await store.needsEmbedding(
            document: document,
            descriptor: spanish
        )
        let needsNewerEnglish = try await store.needsEmbedding(
            document: document,
            descriptor: newerEnglish
        )
        XCTAssertTrue(needsSpanish)
        XCTAssertTrue(needsNewerEnglish)

        let matches = try await store.search(LocalSearchRequest(
            queryText: "plot",
            queryVector: [1, 0, 0],
            descriptor: spanish
        ))
        XCTAssertTrue(matches.isEmpty)
    }

    func testCorruptDatabaseRebuildsAsEmptyCache() async throws {
        let directory = try tempDirectory()
        let databaseURL = directory.appendingPathComponent("search-index-profile.sqlite")
        try Data("not a sqlite database".utf8).write(to: databaseURL)
        let store = LocalSearchIndex(scopeKey: "profile", directory: directory)
        let count = try await store.documentCount()
        XCTAssertEqual(count, 0)
    }

    func testPageSizedBatchCommitsInOneGeneration() async throws {
        let store = LocalSearchIndex(scopeKey: "profile", directory: try tempDirectory())
        let token = await store.activateWriteGeneration()
        let builder = SearchDocumentBuilder()
        let writes = (0..<200).map { index in
            let document = builder.document(
                for: item(
                    id: String(index),
                    title: "Episode \(index)",
                    overview: "Synthetic plot \(index)",
                    episode: index + 1
                ),
                accountID: "a",
                providerUserKey: "u"
            )
            return SearchIndexWrite(
                document: document,
                embeddings: [
                    SearchDocumentEmbedding(
                        segment: 0,
                        descriptor: descriptor,
                        vector: [1, Float(index % 2), 0]
                    )
                ]
            )
        }

        try await store.upsert(
            writes,
            scanGeneration: 1,
            writeToken: token
        )
        let count = try await store.documentCount()
        XCTAssertEqual(count, 200)
    }

    func testStoreTopKUsesStableSourceOrderForTies() async throws {
        let store = LocalSearchIndex(scopeKey: "profile", directory: try tempDirectory())
        let token = await store.activateWriteGeneration()
        let builder = SearchDocumentBuilder()
        let writes = ["b", "a"].map { id in
            SearchIndexWrite(
                document: builder.document(
                    for: item(id: id, title: "Same", overview: "Same plot"),
                    accountID: "account",
                    providerUserKey: "user"
                ),
                embeddings: [
                    SearchDocumentEmbedding(
                        segment: 0,
                        descriptor: descriptor,
                        vector: [1, 0, 0]
                    )
                ]
            )
        }
        try await store.upsert(writes, scanGeneration: 1, writeToken: token)

        let matches = try await store.search(LocalSearchRequest(
            queryText: "different query",
            queryVector: [1, 0, 0],
            descriptor: descriptor,
            limit: 1
        ))
        XCTAssertEqual(matches.map(\.sourceKey), ["account:a"])
    }

    func testMismatchedProviderTotalDoesNotPrunePreviousGeneration() async throws {
        let store = LocalSearchIndex(scopeKey: "profile", directory: try tempDirectory())
        let token = await store.activateWriteGeneration()
        let scope = SearchScanScope(
            accountID: "a",
            providerUserKey: "u",
            libraryID: "shows",
            kind: .episode
        )
        let builder = SearchDocumentBuilder()
        let first = try await store.beginOrResumeFullScan(scope: scope, writeToken: token)
        let initial = ["1", "2"].map { id in
            SearchIndexWrite(
                document: builder.document(
                    for: item(id: id, title: id, overview: id),
                    accountID: "a",
                    providerUserKey: "u"
                ),
                embeddings: []
            )
        }
        try await store.upsert(initial, scanGeneration: first.generation, writeToken: token)
        try await store.finishFullScan(
            checkpoint: first,
            writeToken: token,
            expectedTotalCount: 2
        )

        let second = try await store.beginOrResumeFullScan(scope: scope, writeToken: token)
        try await store.upsert(
            [initial[0]],
            scanGeneration: second.generation,
            writeToken: token
        )
        do {
            try await store.finishFullScan(
                checkpoint: second,
                writeToken: token,
                expectedTotalCount: 2
            )
            XCTFail("Expected reconciliation failure")
        } catch {
            XCTAssertEqual(
                error as? SearchIndexStoreError,
                .inconsistentScan(expected: 2, actual: 1)
            )
        }
        let preservedCount = try await store.documentCount()
        XCTAssertEqual(preservedCount, 2)
    }

    func testEmptyPartitionRequiresTwoCompletedScansBeforePruning() async throws {
        let store = LocalSearchIndex(scopeKey: "profile", directory: try tempDirectory())
        let token = await store.activateWriteGeneration()
        let scope = SearchScanScope(
            accountID: "a",
            providerUserKey: "u",
            libraryID: "shows",
            kind: .episode
        )
        let write = SearchIndexWrite(
            document: SearchDocumentBuilder().document(
                for: item(id: "1", title: "One", overview: "One"),
                accountID: "a",
                providerUserKey: "u"
            ),
            embeddings: []
        )
        let first = try await store.beginOrResumeFullScan(scope: scope, writeToken: token)
        try await store.upsert([write], scanGeneration: first.generation, writeToken: token)
        try await store.finishFullScan(
            checkpoint: first,
            writeToken: token,
            expectedTotalCount: 1
        )

        let firstEmpty = try await store.beginOrResumeFullScan(scope: scope, writeToken: token)
        try await store.finishFullScan(
            checkpoint: firstEmpty,
            writeToken: token,
            expectedTotalCount: 0
        )
        let afterFirstEmpty = try await store.documentCount()
        XCTAssertEqual(afterFirstEmpty, 1)

        let secondEmpty = try await store.beginOrResumeFullScan(scope: scope, writeToken: token)
        try await store.finishFullScan(
            checkpoint: secondEmpty,
            writeToken: token,
            expectedTotalCount: 0
        )
        let afterSecondEmpty = try await store.documentCount()
        XCTAssertEqual(afterSecondEmpty, 0)
    }

    func testPersistedVectorsProduceSameRankingAfterReopen() async throws {
        let directory = try tempDirectory()
        let firstStore = LocalSearchIndex(scopeKey: "profile", directory: directory)
        let token = await firstStore.activateWriteGeneration()
        let builder = SearchDocumentBuilder()
        let writes = [
            ("best", [1 as Float, 0, 0]),
            ("other", [0 as Float, 1, 0])
        ].map { id, vector in
            SearchIndexWrite(
                document: builder.document(
                    for: item(id: id, title: id, overview: id),
                    accountID: "account",
                    providerUserKey: "user"
                ),
                embeddings: [
                    SearchDocumentEmbedding(
                        segment: 0,
                        descriptor: descriptor,
                        vector: vector
                    )
                ]
            )
        }
        try await firstStore.upsert(writes, scanGeneration: 1, writeToken: token)
        let request = LocalSearchRequest(
            queryText: "query",
            queryVector: [1, 0, 0],
            descriptor: descriptor,
            limit: 2
        )
        let before = try await firstStore.search(request).map(\.sourceKey)

        let reopened = LocalSearchIndex(scopeKey: "profile", directory: directory)
        let after = try await reopened.search(request).map(\.sourceKey)
        XCTAssertEqual(after, before)
    }

    func testWarmedCacheStaysOnCompletedGenerationUntilScanFinishes() async throws {
        let store = LocalSearchIndex(scopeKey: "profile", directory: try tempDirectory())
        let token = await store.activateWriteGeneration()
        let scope = SearchScanScope(
            accountID: "account",
            providerUserKey: "user",
            libraryID: "shows",
            kind: .episode
        )
        let builder = SearchDocumentBuilder()
        func write(_ id: String, vector: [Float]) -> SearchIndexWrite {
            SearchIndexWrite(
                document: builder.document(
                    for: item(id: id, title: id, overview: id),
                    accountID: "account",
                    providerUserKey: "user"
                ),
                embeddings: [
                    SearchDocumentEmbedding(
                        segment: 0,
                        descriptor: descriptor,
                        vector: vector
                    )
                ]
            )
        }

        let first = try await store.beginOrResumeFullScan(scope: scope, writeToken: token)
        try await store.upsert(
            [write("old", vector: [1, 0, 0])],
            scanGeneration: first.generation,
            writeToken: token
        )
        try await store.finishFullScan(
            checkpoint: first,
            writeToken: token,
            expectedTotalCount: 1
        )
        _ = try await store.warm(descriptor: descriptor)

        let second = try await store.beginOrResumeFullScan(scope: scope, writeToken: token)
        try await store.upsert(
            [
                write("old", vector: [1, 0, 0]),
                write("new", vector: [1, 0, 0])
            ],
            scanGeneration: second.generation,
            writeToken: token
        )
        let request = LocalSearchRequest(
            queryText: "query",
            queryVector: [1, 0, 0],
            descriptor: descriptor,
            limit: 10
        )
        let duringScan = try await store.search(request).map(\.sourceKey)
        XCTAssertEqual(duringScan, ["account:old"])

        try await store.finishFullScan(
            checkpoint: second,
            writeToken: token,
            expectedTotalCount: 2
        )
        let afterCommit = try await store.search(request).map(\.sourceKey)
        XCTAssertEqual(afterCommit, ["account:new", "account:old"])
    }
}
