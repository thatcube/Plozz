import Foundation
import CoreModels

public protocol SearchIndexResourceAdmitting: Sendable {
    func waitForSearchIndexing() async throws
}

public struct ImmediateSearchIndexAdmission: SearchIndexResourceAdmitting {
    public init() {}
    public func waitForSearchIndexing() async throws {
        try Task.checkCancellation()
    }
}

public struct SearchCatalogIndexingPolicy: Sendable {
    public let pageSize: Int
    public let embeddingSliceSize: Int
    public let fullRefreshInterval: TimeInterval

    public init(
        pageSize: Int = 200,
        embeddingSliceSize: Int = 20,
        fullRefreshInterval: TimeInterval = 6 * 60 * 60
    ) {
        self.pageSize = max(1, pageSize)
        self.embeddingSliceSize = max(1, embeddingSliceSize)
        self.fullRefreshInterval = max(0, fullRefreshInterval)
    }
}

public struct SearchCatalogIndexingResult: Equatable, Sendable {
    public let indexedDocuments: Int
    public let embeddedDocuments: Int
    public let pages: Int

    public init(indexedDocuments: Int, embeddedDocuments: Int, pages: Int) {
        self.indexedDocuments = indexedDocuments
        self.embeddedDocuments = embeddedDocuments
        self.pages = pages
    }
}

public enum SearchCatalogIndexingError: Error, Equatable {
    case unsupportedPartition
    case inconsistentProviderTotal(previous: Int, current: Int)
}

/// Provider-independent full-scan loop. Provider adapters only expose stable
/// pages; this type owns resume cursors, local document construction, serial
/// embedding slices, batch SQLite writes, and safe final pruning.
public struct SearchCatalogIndexer: Sendable {
    private let provider: any SearchCatalogProviding
    private let index: LocalSearchIndex
    private let embeddingProvider: any SentenceEmbeddingProviding
    private let languageDetector: any SearchLanguageDetecting
    private let admission: any SearchIndexResourceAdmitting
    private let policy: SearchCatalogIndexingPolicy
    private let documentBuilder = SearchDocumentBuilder()

    public init(
        provider: any SearchCatalogProviding,
        index: LocalSearchIndex,
        embeddingProvider: any SentenceEmbeddingProviding,
        languageDetector: any SearchLanguageDetecting,
        admission: any SearchIndexResourceAdmitting = ImmediateSearchIndexAdmission(),
        policy: SearchCatalogIndexingPolicy = SearchCatalogIndexingPolicy()
    ) {
        self.provider = provider
        self.index = index
        self.embeddingProvider = embeddingProvider
        self.languageDetector = languageDetector
        self.admission = admission
        self.policy = policy
    }

    public func index(
        scope: SearchScanScope,
        writeToken: UUID
    ) async throws -> SearchCatalogIndexingResult {
        var checkpoint = try await index.beginOrResumeFullScan(
            scope: scope,
            writeToken: writeToken
        )
        var cursor = checkpoint.cursor.flatMap { $0.isEmpty ? nil : $0 }
        var indexedDocuments = 0
        var embeddedDocuments = 0
        var pages = 0
        var expectedTotalCount: Int?

        while true {
            try await admission.waitForSearchIndexing()
            let page = try await provider.searchCatalogPage(
                SearchCatalogPageRequest(
                    libraryID: scope.libraryID,
                    kind: scope.kind,
                    cursor: cursor,
                    limit: policy.pageSize
                )
            )
            pages += 1
            guard page.status == .available else {
                try await index.abandonFullScan(
                    checkpoint: checkpoint,
                    writeToken: writeToken
                )
                throw SearchCatalogIndexingError.unsupportedPartition
            }
            if let totalCount = page.totalCount {
                if let expectedTotalCount, expectedTotalCount != totalCount {
                    throw SearchCatalogIndexingError.inconsistentProviderTotal(
                        previous: expectedTotalCount,
                        current: totalCount
                    )
                }
                expectedTotalCount = totalCount
            }

            for start in stride(
                from: 0,
                to: page.records.count,
                by: policy.embeddingSliceSize
            ) {
                try await admission.waitForSearchIndexing()
                let end = min(start + policy.embeddingSliceSize, page.records.count)
                struct Prepared {
                    let record: SearchCatalogRecord
                    let document: SearchIndexDocument
                    let descriptor: EmbeddingModelDescriptor?
                    let semanticText: String
                }
                var prepared: [Prepared] = []
                prepared.reserveCapacity(end - start)
                for record in page.records[start..<end] {
                    try Task.checkCancellation()
                    let document = documentBuilder.document(
                        for: record.item,
                        accountID: scope.accountID,
                        providerUserKey: scope.providerUserKey
                    )
                    let semanticText = document.semanticTexts.last
                        ?? document.metadataText
                    let language = await languageDetector
                        .hypotheses(for: semanticText, maximumCount: 1)
                        .first ?? .english
                    let descriptor = await embeddingProvider.descriptor(for: language)
                    prepared.append(Prepared(
                        record: record,
                        document: document,
                        descriptor: descriptor,
                        semanticText: semanticText
                    ))
                }

                var neededByDescriptor: [EmbeddingModelDescriptor: Set<String>] = [:]
                for (descriptor, values) in Dictionary(
                    grouping: prepared.compactMap { value in
                        value.descriptor.map { ($0, value.document) }
                    },
                    by: \.0
                ) {
                    neededByDescriptor[descriptor] = try await index
                        .sourceKeysNeedingEmbedding(
                            documents: values.map(\.1),
                            descriptor: descriptor
                        )
                }

                var writes: [SearchIndexWrite] = []
                writes.reserveCapacity(prepared.count)
                for value in prepared {
                    let embeddings: [SearchDocumentEmbedding]?
                    if let descriptor = value.descriptor {
                        let needsEmbedding = neededByDescriptor[descriptor]?
                            .contains(value.document.sourceKey) ?? true
                        if needsEmbedding {
                            if let vector = await embeddingProvider.vector(
                                for: value.semanticText,
                                using: descriptor
                            ) {
                                embeddings = [
                                    SearchDocumentEmbedding(
                                        segment: 0,
                                        descriptor: descriptor,
                                        vector: vector
                                    )
                                ]
                            } else {
                                embeddings = []
                            }
                        } else {
                            embeddings = nil
                        }
                    } else {
                        embeddings = []
                    }
                    if embeddings?.isEmpty == false {
                        embeddedDocuments += 1
                    }
                    writes.append(SearchIndexWrite(
                        document: value.document,
                        embeddings: embeddings
                    ))
                }

                try await index.upsert(
                    writes,
                    scanGeneration: checkpoint.generation,
                    writeToken: writeToken
                )
                indexedDocuments += writes.count
                await Task.yield()
            }

            try await index.saveCursor(
                page.nextCursor,
                checkpoint: checkpoint,
                writeToken: writeToken
            )
            guard let nextCursor = page.nextCursor else {
                try await index.finishFullScan(
                    checkpoint: checkpoint,
                    writeToken: writeToken,
                    expectedTotalCount: expectedTotalCount
                )
                return SearchCatalogIndexingResult(
                    indexedDocuments: indexedDocuments,
                    embeddedDocuments: embeddedDocuments,
                    pages: pages
                )
            }
            guard nextCursor != cursor || !page.records.isEmpty else {
                throw SearchIndexStoreError.invalidCheckpoint
            }
            cursor = nextCursor
            checkpoint = SearchScanCheckpoint(
                scope: checkpoint.scope,
                generation: checkpoint.generation,
                cursor: nextCursor
            )
        }
    }

}
