import Foundation
import SQLite3
import CoreModels

public enum SearchIndexStoreError: Error, Equatable {
    case openFailed(String)
    case sqlite(SearchIndexSQLiteFailure)
    case unsupportedSchema(Int)
    case staleWriteGeneration
    case invalidCheckpoint
    case inconsistentScan(expected: Int, actual: Int)
}

public struct SearchDocumentEmbedding: Sendable {
    public let segment: Int
    public let descriptor: EmbeddingModelDescriptor
    public let vector: [Float]

    public init(
        segment: Int,
        descriptor: EmbeddingModelDescriptor,
        vector: [Float]
    ) {
        self.segment = segment
        self.descriptor = descriptor
        self.vector = vector
    }
}

public struct SearchIndexWrite: Sendable {
    public let document: SearchIndexDocument
    public let embeddings: [SearchDocumentEmbedding]?

    public init(
        document: SearchIndexDocument,
        embeddings: [SearchDocumentEmbedding]?
    ) {
        self.document = document
        self.embeddings = embeddings
    }
}

public struct SearchScanScope: Codable, Hashable, Sendable {
    public let accountID: String
    public let providerUserKey: String
    public let libraryID: String
    public let kind: MediaItemKind

    public init(
        accountID: String,
        providerUserKey: String,
        libraryID: String,
        kind: MediaItemKind
    ) {
        self.accountID = accountID
        self.providerUserKey = providerUserKey
        self.libraryID = libraryID
        self.kind = kind
    }
}

public struct SearchScanCheckpoint: Equatable, Sendable {
    public let scope: SearchScanScope
    public let generation: Int64
    public let cursor: Data?

    public init(scope: SearchScanScope, generation: Int64, cursor: Data?) {
        self.scope = scope
        self.generation = generation
        self.cursor = cursor
    }
}

public struct LocalSearchRequest: Sendable {
    public let queryText: String
    public let queryVector: [Float]
    public let descriptor: EmbeddingModelDescriptor
    public let intent: LocalSearchIntent
    public let excludedLibraryKeys: Set<String>
    public let limit: Int
    public let minimumSemanticScore: Float
    public let rankingWeights: HybridRankingWeights

    public init(
        queryText: String,
        queryVector: [Float],
        descriptor: EmbeddingModelDescriptor,
        intent: LocalSearchIntent = LocalSearchIntent(),
        excludedLibraryKeys: Set<String> = [],
        limit: Int = 40,
        minimumSemanticScore: Float = -.infinity,
        rankingWeights: HybridRankingWeights = HybridRankingWeights()
    ) {
        self.queryText = queryText
        self.queryVector = queryVector
        self.descriptor = descriptor
        self.intent = intent
        self.excludedLibraryKeys = excludedLibraryKeys
        self.limit = limit
        self.minimumSemanticScore = minimumSemanticScore
        self.rankingWeights = rankingWeights
    }
}

public actor LocalSearchIndex {
    private struct CandidateCacheKey: Hashable {
        let descriptor: EmbeddingModelDescriptor
        let kindRawValue: String?
    }

    public nonisolated let databaseURL: URL
    public let storageFormat: VectorStorageFormat

    private var connection: SearchSQLiteConnection?
    private var activeWriteGeneration: UUID?
    private var vectorCache: [CandidateCacheKey: [SemanticCandidate]] = [:]
    private let connectionFactory: @Sendable (URL) throws -> SearchSQLiteConnection

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        scopeKey: String,
        directory: URL? = nil,
        storageFormat: VectorStorageFormat = .float16
    ) {
        let base = directory ?? Self.defaultDirectory()
        try? FileManager.default.createDirectory(
            at: base,
            withIntermediateDirectories: true
        )
        databaseURL = base.appendingPathComponent(
            "search-index-\(Self.sanitize(scopeKey)).sqlite"
        )
        self.storageFormat = storageFormat
        encoder = JSONEncoder()
        decoder = JSONDecoder()
        connectionFactory = { try SearchSQLiteConnection(url: $0) }
    }

    init(
        scopeKey: String,
        directory: URL,
        storageFormat: VectorStorageFormat = .float16,
        connectionFactory: @escaping @Sendable (URL) throws -> SearchSQLiteConnection
    ) {
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        databaseURL = directory.appendingPathComponent(
            "search-index-\(Self.sanitize(scopeKey)).sqlite"
        )
        self.storageFormat = storageFormat
        encoder = JSONEncoder()
        decoder = JSONDecoder()
        self.connectionFactory = connectionFactory
    }

    @discardableResult
    public func activateWriteGeneration() -> UUID {
        let token = UUID()
        activeWriteGeneration = token
        return token
    }

    public func invalidateWriteGeneration() {
        activeWriteGeneration = nil
    }

    public func beginOrResumeFullScan(
        scope: SearchScanScope,
        writeToken: UUID
    ) throws -> SearchScanCheckpoint {
        try requireWriteToken(writeToken)
        try ensureOpen()

        if let checkpoint = try checkpoint(for: scope) {
            return checkpoint
        }

        let nextGeneration = (try maximumGeneration(for: scope)) + 1
        try execute("""
        INSERT INTO sync_state(
          account_id, provider_user_key, library_id, kind, cursor,
          last_full_scan_at, scan_generation, scan_active
        ) VALUES(?,?,?,?,?,NULL,?,1)
        ON CONFLICT(account_id, provider_user_key, library_id, kind) DO UPDATE SET
          cursor=excluded.cursor,
          scan_generation=excluded.scan_generation,
          scan_active=1;
        """) { statement in
            bind(scope, to: statement)
            bindBlob(Data(), to: statement, index: 5)
            sqlite3_bind_int64(statement, 6, nextGeneration)
        }
        return SearchScanCheckpoint(
            scope: scope,
            generation: nextGeneration,
            cursor: Data()
        )
    }

    public func saveCursor(
        _ cursor: Data?,
        checkpoint: SearchScanCheckpoint,
        writeToken: UUID
    ) throws {
        try requireWriteToken(writeToken)
        try ensureOpen()
        let changed = try execute("""
        UPDATE sync_state
        SET cursor=?, scan_active=1
        WHERE account_id=? AND provider_user_key=? AND library_id=? AND kind=?
          AND scan_generation=?;
        """) { statement in
            bindOptionalBlob(cursor, to: statement, index: 1)
            bind(checkpoint.scope, to: statement, startingAt: 2)
            sqlite3_bind_int64(statement, 6, checkpoint.generation)
        }
        guard changed == 1 else { throw SearchIndexStoreError.invalidCheckpoint }
    }

    public func abandonFullScan(
        checkpoint: SearchScanCheckpoint,
        writeToken: UUID
    ) throws {
        try requireWriteToken(writeToken)
        try ensureOpen()
        let changed = try execute("""
        UPDATE sync_state
        SET cursor=NULL, scan_active=0
        WHERE account_id=? AND provider_user_key=? AND library_id=? AND kind=?
          AND scan_generation=?;
        """) { statement in
            bind(checkpoint.scope, to: statement)
            sqlite3_bind_int64(statement, 5, checkpoint.generation)
        }
        guard changed == 1 else { throw SearchIndexStoreError.invalidCheckpoint }
    }

    public func needsEmbedding(
        document: SearchIndexDocument,
        descriptor: EmbeddingModelDescriptor
    ) throws -> Bool {
        try ensureOpen()
        var needs = true
        try query("""
        SELECT d.content_hash, COUNT(v.source_key)
        FROM documents d
        LEFT JOIN vectors v
          ON v.source_key=d.source_key
         AND v.language=? AND v.revision=? AND v.dimension=?
        WHERE d.source_key=?
        GROUP BY d.source_key;
        """, bind: { statement in
            bindText(descriptor.language.rawValue, to: statement, index: 1)
            sqlite3_bind_int64(statement, 2, Int64(descriptor.revision))
            sqlite3_bind_int64(statement, 3, Int64(descriptor.dimension))
            bindText(document.sourceKey, to: statement, index: 4)
        }) { statement in
            let storedHash = columnText(statement, 0)
            let vectorCount = Int(sqlite3_column_int64(statement, 1))
            needs = storedHash != document.contentHash || vectorCount == 0
        }
        return needs
    }

    public func sourceKeysNeedingEmbedding(
        documents: [SearchIndexDocument],
        descriptor: EmbeddingModelDescriptor
    ) throws -> Set<String> {
        try ensureOpen()
        guard !documents.isEmpty else { return [] }
        let byKey = Dictionary(
            documents.map { ($0.sourceKey, $0.contentHash) },
            uniquingKeysWith: { first, _ in first }
        )
        var needed = Set(byKey.keys)
        let placeholders = Array(repeating: "?", count: documents.count)
            .joined(separator: ",")
        try query("""
        SELECT d.source_key, d.content_hash, COUNT(v.source_key)
        FROM documents d
        LEFT JOIN vectors v
          ON v.source_key=d.source_key
         AND v.language=? AND v.revision=? AND v.dimension=?
        WHERE d.source_key IN (\(placeholders))
        GROUP BY d.source_key;
        """, bind: { statement in
            bindText(descriptor.language.rawValue, to: statement, index: 1)
            sqlite3_bind_int64(statement, 2, Int64(descriptor.revision))
            sqlite3_bind_int64(statement, 3, Int64(descriptor.dimension))
            for (offset, document) in documents.enumerated() {
                bindText(
                    document.sourceKey,
                    to: statement,
                    index: Int32(offset + 4)
                )
            }
        }) { statement in
            guard let sourceKey = columnText(statement, 0),
                  let expectedHash = byKey[sourceKey] else {
                return
            }
            let storedHash = columnText(statement, 1)
            let vectorCount = Int(sqlite3_column_int64(statement, 2))
            if storedHash == expectedHash, vectorCount > 0 {
                needed.remove(sourceKey)
            }
        }
        return needed
    }

    public func upsert(
        document: SearchIndexDocument,
        embeddings: [SearchDocumentEmbedding]?,
        scanGeneration: Int64,
        writeToken: UUID
    ) throws {
        try upsert(
            [
                SearchIndexWrite(
                    document: document,
                    embeddings: embeddings
                )
            ],
            scanGeneration: scanGeneration,
            writeToken: writeToken
        )
    }

    public func upsert(
        _ writes: [SearchIndexWrite],
        scanGeneration: Int64,
        writeToken: UUID
    ) throws {
        try requireWriteToken(writeToken)
        try ensureOpen()
        guard !writes.isEmpty else { return }
        let preserveCompletedGenerationCache = try hasActiveScan()
        try transaction {
            for write in writes {
                try upsert(
                    write,
                    scanGeneration: scanGeneration
                )
            }
        }
        // A warmed cache represents the last completed generation. Keep serving
        // that stable snapshot while a new page-based scan writes in the
        // background; `finishFullScan` invalidates it once the generation commits.
        if !preserveCompletedGenerationCache {
            vectorCache.removeAll()
        }
    }

    private func upsert(
        _ write: SearchIndexWrite,
        scanGeneration: Int64
    ) throws {
        let document = write.document
        let itemData = try encoder.encode(document.item)
        try execute("""
            INSERT INTO documents(
              source_key, account_id, provider_user_key, item_id, library_id,
              kind, title_normalized, parent_title_normalized, metadata_text,
              media_item_json, content_hash,               scan_generation
            ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(source_key) DO UPDATE SET
              account_id=excluded.account_id,
              provider_user_key=excluded.provider_user_key,
              item_id=excluded.item_id,
              library_id=excluded.library_id,
              kind=excluded.kind,
              title_normalized=excluded.title_normalized,
              parent_title_normalized=excluded.parent_title_normalized,
              metadata_text=excluded.metadata_text,
              media_item_json=excluded.media_item_json,
              content_hash=excluded.content_hash,
              scan_generation=excluded.scan_generation;
            """) { statement in
                bindText(document.sourceKey, to: statement, index: 1)
                bindText(document.accountID, to: statement, index: 2)
                bindText(document.providerUserKey, to: statement, index: 3)
                bindText(document.item.id, to: statement, index: 4)
                bindText(document.libraryID ?? "", to: statement, index: 5)
                bindText(document.item.kind.rawValue, to: statement, index: 6)
                bindText(document.normalizedTitle, to: statement, index: 7)
                bindOptionalText(document.normalizedParentTitle, to: statement, index: 8)
                bindText(document.metadataText, to: statement, index: 9)
                bindBlob(itemData, to: statement, index: 10)
                bindText(document.contentHash, to: statement, index: 11)
                sqlite3_bind_int64(statement, 12, scanGeneration)
            }

        guard let embeddings = write.embeddings else { return }
        try execute("DELETE FROM vectors WHERE source_key=?;") { statement in
            bindText(document.sourceKey, to: statement, index: 1)
        }
        for embedding in embeddings {
            let normalized = try VectorMath.normalized(embedding.vector)
            let data = try VectorCodec.encode(normalized, format: storageFormat)
            try execute("""
                INSERT INTO vectors(
                  source_key, segment, language, revision, dimension,
                  storage_format, vector_data
                ) VALUES(?,?,?,?,?,?,?);
                """) { statement in
                    bindText(document.sourceKey, to: statement, index: 1)
                    sqlite3_bind_int64(statement, 2, Int64(embedding.segment))
                    bindText(embedding.descriptor.language.rawValue, to: statement, index: 3)
                    sqlite3_bind_int64(statement, 4, Int64(embedding.descriptor.revision))
                    sqlite3_bind_int64(statement, 5, Int64(embedding.descriptor.dimension))
                    bindText(storageFormat.rawValue, to: statement, index: 6)
                    bindBlob(data, to: statement, index: 7)
                }
        }
    }

    public func patchItem(_ item: MediaItem, sourceKey: String) throws {
        try ensureOpen()
        let itemData = try encoder.encode(item)
        try execute("UPDATE documents SET media_item_json=? WHERE source_key=?;") { statement in
            bindBlob(itemData, to: statement, index: 1)
            bindText(sourceKey, to: statement, index: 2)
        }
    }

    public func finishFullScan(
        checkpoint: SearchScanCheckpoint,
        writeToken: UUID,
        expectedTotalCount: Int?,
        completedAt: Date = Date()
    ) throws {
        try requireWriteToken(writeToken)
        try ensureOpen()
        let actualCount = try currentGenerationCount(checkpoint)
        if let expectedTotalCount, actualCount != expectedTotalCount {
            throw SearchIndexStoreError.inconsistentScan(
                expected: expectedTotalCount,
                actual: actualCount
            )
        }
        let shouldPrune: Bool
        if let expectedTotalCount {
            if expectedTotalCount == 0 {
                let newestStoredGeneration = try newestStoredGeneration(checkpoint.scope)
                shouldPrune = newestStoredGeneration == nil ||
                    newestStoredGeneration! <= checkpoint.generation - 2
            } else {
                shouldPrune = true
            }
        } else {
            shouldPrune = false
        }
        try transaction {
            if shouldPrune {
                try execute("""
                DELETE FROM documents
                WHERE account_id=? AND provider_user_key=?
                  AND library_id=?
                  AND kind=?
                  AND scan_generation < ?;
                """) { statement in
                    bindText(checkpoint.scope.accountID, to: statement, index: 1)
                    bindText(checkpoint.scope.providerUserKey, to: statement, index: 2)
                    bindText(checkpoint.scope.libraryID, to: statement, index: 3)
                    bindText(checkpoint.scope.kind.rawValue, to: statement, index: 4)
                    sqlite3_bind_int64(statement, 5, checkpoint.generation)
                }
            }
            let changed = try execute("""
            UPDATE sync_state
            SET cursor=NULL, last_full_scan_at=?, scan_active=0
            WHERE account_id=? AND provider_user_key=? AND library_id=? AND kind=?
              AND scan_generation=?;
            """) { statement in
                sqlite3_bind_double(statement, 1, completedAt.timeIntervalSince1970)
                bind(checkpoint.scope, to: statement, startingAt: 2)
                sqlite3_bind_int64(statement, 6, checkpoint.generation)
            }
            guard changed == 1 else { throw SearchIndexStoreError.invalidCheckpoint }
        }
        vectorCache.removeAll()
    }

    private func currentGenerationCount(
        _ checkpoint: SearchScanCheckpoint
    ) throws -> Int {
        var count = 0
        try query("""
        SELECT COUNT(*) FROM documents
        WHERE account_id=? AND provider_user_key=? AND library_id=? AND kind=?
          AND scan_generation=?;
        """, bind: { statement in
            bind(checkpoint.scope, to: statement)
            sqlite3_bind_int64(statement, 5, checkpoint.generation)
        }) { statement in
            count = Int(sqlite3_column_int64(statement, 0))
        }
        return count
    }

    private func newestStoredGeneration(
        _ scope: SearchScanScope
    ) throws -> Int64? {
        var generation: Int64?
        try query("""
        SELECT MAX(scan_generation) FROM documents
        WHERE account_id=? AND provider_user_key=? AND library_id=? AND kind=?;
        """, bind: { statement in
            bind(scope, to: statement)
        }) { statement in
            if sqlite3_column_type(statement, 0) != SQLITE_NULL {
                generation = sqlite3_column_int64(statement, 0)
            }
        }
        return generation
    }

    public func checkpoint(for scope: SearchScanScope) throws -> SearchScanCheckpoint? {
        try ensureOpen()
        var result: SearchScanCheckpoint?
        try query("""
        SELECT scan_generation, cursor, scan_active
        FROM sync_state
        WHERE account_id=? AND provider_user_key=? AND library_id=? AND kind=?;
        """, bind: { statement in
            bind(scope, to: statement)
        }) { statement in
            guard sqlite3_column_int(statement, 2) == 1 else { return }
            result = SearchScanCheckpoint(
                scope: scope,
                generation: sqlite3_column_int64(statement, 0),
                cursor: columnBlob(statement, 1)
            )
        }
        return result
    }

    public func needsFullScan(
        scope: SearchScanScope,
        refreshInterval: TimeInterval,
        now: Date = Date()
    ) throws -> Bool {
        try ensureOpen()
        if try checkpoint(for: scope) != nil { return true }
        var lastFullScanAt: Date?
        try query("""
        SELECT last_full_scan_at FROM sync_state
        WHERE account_id=? AND provider_user_key=? AND library_id=? AND kind=?;
        """, bind: { statement in
            bind(scope, to: statement)
        }) { statement in
            if sqlite3_column_type(statement, 0) != SQLITE_NULL {
                lastFullScanAt = Date(
                    timeIntervalSince1970: sqlite3_column_double(statement, 0)
                )
            }
        }
        guard let lastFullScanAt else { return true }
        return now.timeIntervalSince(lastFullScanAt) >= refreshInterval
    }

    public func remove(accountID: String) throws {
        try ensureOpen()
        try execute("DELETE FROM documents WHERE account_id=?;") { statement in
            bindText(accountID, to: statement, index: 1)
        }
        try execute("DELETE FROM sync_state WHERE account_id=?;") { statement in
            bindText(accountID, to: statement, index: 1)
        }
        vectorCache.removeAll()
    }

    public func remove(libraryKeys: Set<String>) throws {
        try ensureOpen()
        for key in libraryKeys {
            guard let separator = key.firstIndex(of: ":") else { continue }
            let accountID = String(key[..<separator])
            let libraryID = String(key[key.index(after: separator)...])
            try execute("""
            DELETE FROM documents
            WHERE account_id=? AND library_id=?;
            """) { statement in
                bindText(accountID, to: statement, index: 1)
                bindText(libraryID, to: statement, index: 2)
            }
        }
        vectorCache.removeAll()
    }

    public func removeAll() throws {
        try ensureOpen()
        try transaction {
            try execute("DELETE FROM documents;")
            try execute("DELETE FROM sync_state;")
        }
        vectorCache.removeAll()
    }

    public func retainOnly(
        accountIDs: Set<String>,
        reconciledAccountIDs: Set<String>,
        libraryKeys: Set<String>,
        providerUserKeysByAccount: [String: String]
    ) throws {
        try ensureOpen()
        struct StoredScope: Hashable {
            let accountID: String
            let libraryID: String
            let providerUserKey: String
        }
        var removals: [StoredScope] = []
        try query("""
        SELECT DISTINCT account_id, library_id, provider_user_key FROM documents;
        """) {
            statement in
            guard let accountID = columnText(statement, 0),
                  let libraryID = columnText(statement, 1),
                  let providerUserKey = columnText(statement, 2) else {
                return
            }
            let shouldRemoveAccount = !accountIDs.contains(accountID)
            let shouldReconcile = reconciledAccountIDs.contains(accountID)
            let wrongLibrary = shouldReconcile &&
                !libraryKeys.contains("\(accountID):\(libraryID)")
            let wrongProviderUser = providerUserKeysByAccount[accountID]
                .map { $0 != providerUserKey } ?? false
            if shouldRemoveAccount || wrongLibrary || wrongProviderUser {
                removals.append(StoredScope(
                    accountID: accountID,
                    libraryID: libraryID,
                    providerUserKey: providerUserKey
                ))
            }
        }
        guard !removals.isEmpty else { return }
        try transaction {
            for removal in removals {
                try execute("""
                DELETE FROM documents
                WHERE account_id=? AND library_id=? AND provider_user_key=?;
                """) { statement in
                    bindText(removal.accountID, to: statement, index: 1)
                    bindText(removal.libraryID, to: statement, index: 2)
                    bindText(removal.providerUserKey, to: statement, index: 3)
                }
                try execute("""
                DELETE FROM sync_state
                WHERE account_id=? AND library_id=? AND provider_user_key=?;
                """) { statement in
                    bindText(removal.accountID, to: statement, index: 1)
                    bindText(removal.libraryID, to: statement, index: 2)
                    bindText(removal.providerUserKey, to: statement, index: 3)
                }
            }
        }
        vectorCache.removeAll()
    }

    public func releaseVectorCache() {
        vectorCache.removeAll()
    }

    public func deleteCacheFiles() throws {
        connection?.close()
        connection = nil
        vectorCache.removeAll()
        for url in [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm")
        ] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    public func documentCount() throws -> Int {
        try ensureOpen()
        return try scalarInt("SELECT COUNT(*) FROM documents;")
    }

    @discardableResult
    public func warm(
        descriptor: EmbeddingModelDescriptor,
        kind: MediaItemKind? = nil
    ) throws -> Int {
        try ensureOpen()
        return try candidates(for: descriptor, kind: kind).count
    }

    public func search(_ request: LocalSearchRequest) async throws -> [SearchIndexMatch] {
        try ensureOpen()
        guard request.limit > 0,
              let queryVector = try? VectorMath.normalized(request.queryVector),
              queryVector.count == request.descriptor.dimension else {
            return []
        }

        let kindFilter = request.intent.kinds.count == 1
            ? request.intent.kinds.first
            : nil
        let candidates = try candidates(
            for: request.descriptor,
            kind: kindFilter
        )
        let hasPostHydrationFilters = request.intent.seriesTitle != nil ||
            request.intent.seasonNumber != nil ||
            request.intent.episodeNumber != nil ||
            request.intent.minimumYear != nil ||
            request.intent.maximumYear != nil ||
            !request.intent.genres.isEmpty ||
            request.intent.runtime != nil
        let candidateLimit = min(
            candidates.count,
            hasPostHydrationFilters
                ? max(request.limit * 32, 2_048)
                : max(request.limit * 8, 256)
        )
        let semantic = try await SemanticRanker.topMatches(
            query: queryVector,
            candidates: candidates,
            limit: candidateLimit,
            minimumScore: request.minimumSemanticScore
        )
        let hydrated = try loadDocuments(
            sourceKeys: semantic.map(\.sourceKey)
        )
        var rankingInputs: [HybridRankingInput] = []
        rankingInputs.reserveCapacity(semantic.count)

        for score in semantic {
            try Task.checkCancellation()
            guard let document = hydrated[score.sourceKey],
                  matches(
                    item: document.item,
                    accountID: document.accountID,
                    intent: request.intent
                  ),
                  !isExcluded(
                    accountID: document.accountID,
                    libraryID: document.libraryID,
                    keys: request.excludedLibraryKeys
                  ) else {
                continue
            }
            rankingInputs.append(HybridRankingInput(
                sourceKey: score.sourceKey,
                item: document.item,
                metadataText: document.metadataText,
                semanticScore: score.score
            ))
        }
        return try await HybridRankingPolicy(
            weights: request.rankingWeights
        ).rank(
            rankingInputs,
            query: request.queryText,
            limit: request.limit
        )
    }

    private func candidates(
        for descriptor: EmbeddingModelDescriptor,
        kind: MediaItemKind?
    ) throws -> [SemanticCandidate] {
        let cacheKey = CandidateCacheKey(
            descriptor: descriptor,
            kindRawValue: kind?.rawValue
        )
        if let cached = vectorCache[cacheKey] {
            return cached
        }
        var result: [SemanticCandidate] = []
        var currentSourceKey: String?
        var currentVectors: [[Float]] = []
        var rowCount = 0

        func appendCurrent() {
            guard let currentSourceKey, !currentVectors.isEmpty else { return }
            result.append(SemanticCandidate(
                sourceKey: currentSourceKey,
                vectors: currentVectors
            ))
        }
        var sql = """
        SELECT v.source_key, v.dimension, v.storage_format, v.vector_data
        FROM vectors v
        """
        if kind != nil {
            sql += " JOIN documents d ON d.source_key=v.source_key "
        }
        sql += " WHERE v.language=? AND v.revision=? AND v.dimension=? "
        if kind != nil {
            sql += " AND d.kind=? "
        }
        sql += " ORDER BY v.source_key, v.segment;"
        try query(sql, bind: { statement in
            bindText(descriptor.language.rawValue, to: statement, index: 1)
            sqlite3_bind_int64(statement, 2, Int64(descriptor.revision))
            sqlite3_bind_int64(statement, 3, Int64(descriptor.dimension))
            if let kind {
                bindText(kind.rawValue, to: statement, index: 4)
            }
        }) { statement in
            rowCount += 1
            if rowCount.isMultiple(of: 256) {
                try Task.checkCancellation()
            }
            guard let sourceKey = columnText(statement, 0),
                  let formatRaw = columnText(statement, 2),
                  let format = VectorStorageFormat(rawValue: formatRaw),
                  let vectorData = columnBlob(statement, 3),
                  let vector = try? VectorCodec.decode(
                    vectorData,
                    format: format,
                    dimension: Int(sqlite3_column_int64(statement, 1))
                  ) else {
                return
            }
            if sourceKey != currentSourceKey {
                appendCurrent()
                currentSourceKey = sourceKey
                currentVectors = []
            }
            currentVectors.append(vector)
        }
        appendCurrent()
        vectorCache[cacheKey] = result
        return result
    }

    private func loadDocuments(
        sourceKeys: [String]
    ) throws -> [String: (accountID: String, libraryID: String?, item: MediaItem, metadataText: String)] {
        guard !sourceKeys.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: sourceKeys.count)
            .joined(separator: ",")
        var result: [
            String: (accountID: String, libraryID: String?, item: MediaItem, metadataText: String)
        ] = [:]
        try query("""
        SELECT source_key, account_id, library_id, media_item_json, metadata_text
        FROM documents
        WHERE source_key IN (\(placeholders));
        """, bind: { statement in
            for (offset, sourceKey) in sourceKeys.enumerated() {
                bindText(sourceKey, to: statement, index: Int32(offset + 1))
            }
        }) { statement in
            guard let sourceKey = columnText(statement, 0),
                  let accountID = columnText(statement, 1),
                  let itemData = columnBlob(statement, 3),
                  let metadataText = columnText(statement, 4),
                  let item = try? decoder.decode(MediaItem.self, from: itemData) else {
                return
            }
            result[sourceKey] = (
                accountID: accountID,
                libraryID: columnText(statement, 2).flatMap { $0.isEmpty ? nil : $0 },
                item: item,
                metadataText: metadataText
            )
        }
        return result
    }

    private func matches(
        item: MediaItem,
        accountID: String,
        intent: LocalSearchIntent
    ) -> Bool {
        if !intent.kinds.isEmpty, !intent.kinds.contains(item.kind) {
            return false
        }
        if let seriesTitle = intent.seriesTitle {
            let expected = SearchDocumentBuilder.normalized(seriesTitle)
            let actual = SearchDocumentBuilder.normalized(item.parentTitle ?? item.title)
            if actual != expected { return false }
        }
        if let season = intent.seasonNumber, item.seasonNumber != season {
            return false
        }
        if let episode = intent.episodeNumber, item.episodeNumber != episode {
            return false
        }
        if let minimum = intent.minimumYear, (item.productionYear ?? .min) < minimum {
            return false
        }
        if let maximum = intent.maximumYear, (item.productionYear ?? .max) > maximum {
            return false
        }
        if !intent.genres.isEmpty {
            let itemGenres = Set(item.genres.map(SearchDocumentBuilder.normalized))
            if intent.genres.isDisjoint(with: itemGenres) { return false }
        }
        if let runtime = intent.runtime {
            guard let seconds = item.runtime else { return false }
            if let minimum = runtime.minimumSeconds, seconds < minimum { return false }
            if let maximum = runtime.maximumSeconds, seconds > maximum { return false }
        }
        return item.sourceAccountID == nil || item.sourceAccountID == accountID
    }

    private func isExcluded(
        accountID: String,
        libraryID: String?,
        keys: Set<String>
    ) -> Bool {
        guard let libraryID else { return false }
        return keys.contains("\(accountID):\(libraryID)")
    }

    private func maximumGeneration(for scope: SearchScanScope) throws -> Int64 {
        var value: Int64 = 0
        try query("""
        SELECT scan_generation FROM sync_state
        WHERE account_id=? AND provider_user_key=? AND library_id=? AND kind=?;
        """, bind: { statement in
            bind(scope, to: statement)
        }) { statement in
            value = sqlite3_column_int64(statement, 0)
        }
        return value
    }

    private func hasActiveScan() throws -> Bool {
        try scalarInt("SELECT COUNT(*) FROM sync_state WHERE scan_active=1;") > 0
    }

    private func requireWriteToken(_ token: UUID) throws {
        guard token == activeWriteGeneration else {
            throw SearchIndexStoreError.staleWriteGeneration
        }
    }

    private func ensureOpen() throws {
        guard connection == nil else { return }
        do {
            let opened = try connectionFactory(databaseURL)
            try SearchIndexSchemaMigrator().migrate(opened)
            connection = opened
        } catch let error as SearchIndexStoreError {
            guard case let .sqlite(failure) = error, failure.isCorruption else {
                throw error
            }
            connection?.close()
            connection = nil
            try removeDatabaseFiles()
            let rebuilt = try connectionFactory(databaseURL)
            try SearchIndexSchemaMigrator().migrate(rebuilt)
            connection = rebuilt
        }
    }

    private func removeDatabaseFiles() throws {
        for url in [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm")
        ] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func transaction(_ body: () throws -> Void) throws {
        guard let connection else {
            throw SearchIndexStoreError.openFailed(databaseURL.lastPathComponent)
        }
        try connection.transaction(body)
    }

    @discardableResult
    private func execute(
        _ sql: String,
        bind: (OpaquePointer?) -> Void = { _ in }
    ) throws -> Int {
        guard let connection else {
            throw SearchIndexStoreError.openFailed(databaseURL.lastPathComponent)
        }
        return try connection.execute(sql, bind: bind)
    }

    private func query(
        _ sql: String,
        bind: (OpaquePointer?) -> Void = { _ in },
        row: (OpaquePointer?) throws -> Void
    ) throws {
        guard let connection else {
            throw SearchIndexStoreError.openFailed(databaseURL.lastPathComponent)
        }
        try connection.query(sql, bind: bind, row: row)
    }

    private func exec(_ sql: String) throws {
        guard let connection else {
            throw SearchIndexStoreError.openFailed(databaseURL.lastPathComponent)
        }
        try connection.exec(sql)
    }

    private func scalarInt(_ sql: String) throws -> Int {
        guard let connection else {
            throw SearchIndexStoreError.openFailed(databaseURL.lastPathComponent)
        }
        return try connection.scalarInt(sql)
    }

    private func bind(
        _ scope: SearchScanScope,
        to statement: OpaquePointer?,
        startingAt index: Int32 = 1
    ) {
        bindText(scope.accountID, to: statement, index: index)
        bindText(scope.providerUserKey, to: statement, index: index + 1)
        bindText(scope.libraryID, to: statement, index: index + 2)
        bindText(scope.kind.rawValue, to: statement, index: index + 3)
    }

    private func bindText(_ value: String, to statement: OpaquePointer?, index: Int32) {
        connection?.bindText(value, to: statement, index: index)
    }

    private func bindOptionalText(
        _ value: String?,
        to statement: OpaquePointer?,
        index: Int32
    ) {
        if let value {
            bindText(value, to: statement, index: index)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func bindBlob(_ value: Data, to statement: OpaquePointer?, index: Int32) {
        connection?.bindBlob(value, to: statement, index: index)
    }

    private func bindOptionalBlob(
        _ value: Data?,
        to statement: OpaquePointer?,
        index: Int32
    ) {
        if let value {
            bindBlob(value, to: statement, index: index)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func columnText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        connection?.columnText(statement, index)
    }

    private func columnBlob(_ statement: OpaquePointer?, _ index: Int32) -> Data? {
        connection?.columnBlob(statement, index)
    }

    private static func defaultDirectory() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("Plozz", isDirectory: true)
    }

    private static func sanitize(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return String(value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" })
    }
}
