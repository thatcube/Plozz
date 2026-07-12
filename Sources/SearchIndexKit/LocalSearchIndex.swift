import Foundation
import SQLite3
import CoreModels

public enum SearchIndexStoreError: Error, Equatable {
    case openFailed(String)
    case sqlite(String)
    case staleWriteGeneration
    case invalidCheckpoint
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
    public let providerUpdatedAt: Date?

    public init(
        document: SearchIndexDocument,
        embeddings: [SearchDocumentEmbedding]?,
        providerUpdatedAt: Date? = nil
    ) {
        self.document = document
        self.embeddings = embeddings
        self.providerUpdatedAt = providerUpdatedAt
    }
}

public struct SearchScanScope: Codable, Hashable, Sendable {
    public let accountID: String
    public let providerUserKey: String
    public let libraryID: String

    public init(accountID: String, providerUserKey: String, libraryID: String) {
        self.accountID = accountID
        self.providerUserKey = providerUserKey
        self.libraryID = libraryID
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

    public init(
        queryText: String,
        queryVector: [Float],
        descriptor: EmbeddingModelDescriptor,
        intent: LocalSearchIntent = LocalSearchIntent(),
        excludedLibraryKeys: Set<String> = [],
        limit: Int = 40,
        minimumSemanticScore: Float = -.infinity
    ) {
        self.queryText = queryText
        self.queryVector = queryVector
        self.descriptor = descriptor
        self.intent = intent
        self.excludedLibraryKeys = excludedLibraryKeys
        self.limit = limit
        self.minimumSemanticScore = minimumSemanticScore
    }
}

public struct SearchIndexMatch: Sendable {
    public let sourceKey: String
    public let item: MediaItem
    public let semanticScore: Float
    public let combinedScore: Float

    public init(
        sourceKey: String,
        item: MediaItem,
        semanticScore: Float,
        combinedScore: Float
    ) {
        self.sourceKey = sourceKey
        self.item = item
        self.semanticScore = semanticScore
        self.combinedScore = combinedScore
    }
}

public actor LocalSearchIndex {
    public nonisolated let databaseURL: URL
    public let storageFormat: VectorStorageFormat

    private var db: OpaquePointer?
    private var didOpen = false
    private var activeWriteGeneration: UUID?
    private var vectorCache: [EmbeddingModelDescriptor: [SemanticCandidate]] = [:]

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private static let schemaVersion: Int32 = 1
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

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
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
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
          account_id, provider_user_key, library_id, cursor, last_delta_at,
          last_full_scan_at, scan_generation, scan_active
        ) VALUES(?,?,?,?,NULL,NULL,?,1)
        ON CONFLICT(account_id, provider_user_key, library_id) DO UPDATE SET
          cursor=excluded.cursor,
          scan_generation=excluded.scan_generation,
          scan_active=1;
        """) { statement in
            bind(scope, to: statement)
            sqlite3_bind_blob(statement, 4, nil, 0, Self.transient)
            sqlite3_bind_int64(statement, 5, nextGeneration)
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
        WHERE account_id=? AND provider_user_key=? AND library_id=?
          AND scan_generation=?;
        """) { statement in
            bindOptionalBlob(cursor, to: statement, index: 1)
            bind(checkpoint.scope, to: statement, startingAt: 2)
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

    public func upsert(
        document: SearchIndexDocument,
        embeddings: [SearchDocumentEmbedding]?,
        providerUpdatedAt: Date? = nil,
        scanGeneration: Int64,
        writeToken: UUID
    ) throws {
        try upsert(
            [
                SearchIndexWrite(
                    document: document,
                    embeddings: embeddings,
                    providerUpdatedAt: providerUpdatedAt
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
        try transaction {
            for write in writes {
                try upsert(
                    write,
                    scanGeneration: scanGeneration
                )
            }
        }
        vectorCache.removeAll()
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
              media_item_json, content_hash, provider_updated_at, scan_generation
            ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
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
              provider_updated_at=excluded.provider_updated_at,
              scan_generation=excluded.scan_generation;
            """) { statement in
                bindText(document.sourceKey, to: statement, index: 1)
                bindText(document.accountID, to: statement, index: 2)
                bindText(document.providerUserKey, to: statement, index: 3)
                bindText(document.item.id, to: statement, index: 4)
                bindOptionalText(document.libraryID, to: statement, index: 5)
                bindText(document.item.kind.rawValue, to: statement, index: 6)
                bindText(document.normalizedTitle, to: statement, index: 7)
                bindOptionalText(document.normalizedParentTitle, to: statement, index: 8)
                bindText(document.metadataText, to: statement, index: 9)
                bindBlob(itemData, to: statement, index: 10)
                bindText(document.contentHash, to: statement, index: 11)
                bindOptionalDate(write.providerUpdatedAt, to: statement, index: 12)
                sqlite3_bind_int64(statement, 13, scanGeneration)
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
        completedAt: Date = Date()
    ) throws {
        try requireWriteToken(writeToken)
        try ensureOpen()
        try transaction {
            try execute("""
            DELETE FROM documents
            WHERE account_id=? AND provider_user_key=?
              AND COALESCE(library_id, '')=?
              AND scan_generation < ?;
            """) { statement in
                bindText(checkpoint.scope.accountID, to: statement, index: 1)
                bindText(checkpoint.scope.providerUserKey, to: statement, index: 2)
                bindText(checkpoint.scope.libraryID, to: statement, index: 3)
                sqlite3_bind_int64(statement, 4, checkpoint.generation)
            }
            let changed = try execute("""
            UPDATE sync_state
            SET cursor=NULL, last_full_scan_at=?, scan_active=0
            WHERE account_id=? AND provider_user_key=? AND library_id=?
              AND scan_generation=?;
            """) { statement in
                sqlite3_bind_double(statement, 1, completedAt.timeIntervalSince1970)
                bind(checkpoint.scope, to: statement, startingAt: 2)
                sqlite3_bind_int64(statement, 5, checkpoint.generation)
            }
            guard changed == 1 else { throw SearchIndexStoreError.invalidCheckpoint }
        }
        vectorCache.removeAll()
    }

    public func checkpoint(for scope: SearchScanScope) throws -> SearchScanCheckpoint? {
        try ensureOpen()
        var result: SearchScanCheckpoint?
        try query("""
        SELECT scan_generation, cursor, scan_active
        FROM sync_state
        WHERE account_id=? AND provider_user_key=? AND library_id=?;
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
            WHERE account_id=? AND COALESCE(library_id, '')=?;
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

    public func documentCount() throws -> Int {
        try ensureOpen()
        return try scalarInt("SELECT COUNT(*) FROM documents;")
    }

    @discardableResult
    public func warm(descriptor: EmbeddingModelDescriptor) throws -> Int {
        try ensureOpen()
        return try candidates(for: descriptor).count
    }

    public func search(_ request: LocalSearchRequest) async throws -> [SearchIndexMatch] {
        try ensureOpen()
        guard request.limit > 0,
              let queryVector = try? VectorMath.normalized(request.queryVector),
              queryVector.count == request.descriptor.dimension else {
            return []
        }

        let candidates = try candidates(for: request.descriptor)
        let hasHardFilters = !request.intent.kinds.isEmpty ||
            request.intent.seriesTitle != nil ||
            request.intent.seasonNumber != nil ||
            request.intent.episodeNumber != nil ||
            request.intent.minimumYear != nil ||
            request.intent.maximumYear != nil ||
            !request.intent.genres.isEmpty ||
            request.intent.runtime != nil
        let candidateLimit = min(
            candidates.count,
            hasHardFilters
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
        var best: [SearchIndexMatch] = []

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
            let match = SearchIndexMatch(
                sourceKey: score.sourceKey,
                item: document.item,
                semanticScore: score.score,
                combinedScore: score.score + HybridSearchScorer.lexicalBoost(
                    query: request.queryText,
                    title: document.item.title,
                    metadataText: document.metadataText
                )
            )
            let worst = best.last
            let shouldInsert = best.count < request.limit ||
                match.combinedScore > (worst?.combinedScore ?? -.infinity)
            if shouldInsert {
                let insertion = best.firstIndex { existing in
                    match.combinedScore > existing.combinedScore
                } ?? best.endIndex
                best.insert(match, at: insertion)
                if best.count > request.limit {
                    best.removeLast()
                }
            }
        }
        return best
    }

    private func candidates(
        for descriptor: EmbeddingModelDescriptor
    ) throws -> [SemanticCandidate] {
        if let cached = vectorCache[descriptor] {
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
        try query("""
        SELECT source_key, dimension, storage_format, vector_data
        FROM vectors
        WHERE language=? AND revision=? AND dimension=?
        ORDER BY source_key, segment;
        """, bind: { statement in
            bindText(descriptor.language.rawValue, to: statement, index: 1)
            sqlite3_bind_int64(statement, 2, Int64(descriptor.revision))
            sqlite3_bind_int64(statement, 3, Int64(descriptor.dimension))
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
        vectorCache[descriptor] = result
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
                libraryID: columnText(statement, 2),
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
        WHERE account_id=? AND provider_user_key=? AND library_id=?;
        """, bind: { statement in
            bind(scope, to: statement)
        }) { statement in
            value = sqlite3_column_int64(statement, 0)
        }
        return value
    }

    private func requireWriteToken(_ token: UUID) throws {
        guard token == activeWriteGeneration else {
            throw SearchIndexStoreError.staleWriteGeneration
        }
    }

    private func ensureOpen() throws {
        guard !didOpen else {
            if db == nil { throw SearchIndexStoreError.openFailed(databaseURL.lastPathComponent) }
            return
        }
        didOpen = true
        do {
            try openAndCreateSchema()
        } catch {
            if let db {
                sqlite3_close(db)
                self.db = nil
            }
            try? FileManager.default.removeItem(at: databaseURL)
            try openAndCreateSchema()
        }
    }

    private func openAndCreateSchema() throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &handle, flags, nil) == SQLITE_OK,
              let handle else {
            if let handle { sqlite3_close(handle) }
            throw SearchIndexStoreError.openFailed(databaseURL.lastPathComponent)
        }
        db = handle
        try exec("PRAGMA foreign_keys=ON;")
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA synchronous=NORMAL;")

        let version = try scalarInt("PRAGMA user_version;")
        guard version == 0 || version == Int(Self.schemaVersion) else {
            throw SearchIndexStoreError.sqlite("unsupported schema \(version)")
        }
        try exec("""
        CREATE TABLE IF NOT EXISTS documents(
          source_key TEXT PRIMARY KEY,
          account_id TEXT NOT NULL,
          provider_user_key TEXT NOT NULL,
          item_id TEXT NOT NULL,
          library_id TEXT,
          kind TEXT NOT NULL,
          title_normalized TEXT NOT NULL,
          parent_title_normalized TEXT,
          metadata_text TEXT NOT NULL,
          media_item_json BLOB NOT NULL,
          content_hash TEXT NOT NULL,
          provider_updated_at REAL,
          scan_generation INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_search_documents_scope
          ON documents(account_id, provider_user_key, library_id, kind);
        CREATE TABLE IF NOT EXISTS vectors(
          source_key TEXT NOT NULL REFERENCES documents(source_key) ON DELETE CASCADE,
          segment INTEGER NOT NULL,
          language TEXT NOT NULL,
          revision INTEGER NOT NULL,
          dimension INTEGER NOT NULL,
          storage_format TEXT NOT NULL,
          vector_data BLOB NOT NULL,
          PRIMARY KEY(source_key, segment)
        );
        CREATE INDEX IF NOT EXISTS idx_search_vectors_model
          ON vectors(language, revision, dimension);
        CREATE TABLE IF NOT EXISTS sync_state(
          account_id TEXT NOT NULL,
          provider_user_key TEXT NOT NULL,
          library_id TEXT NOT NULL,
          cursor BLOB,
          last_delta_at REAL,
          last_full_scan_at REAL,
          scan_generation INTEGER NOT NULL,
          scan_active INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY(account_id, provider_user_key, library_id)
        );
        """)
        try exec("PRAGMA user_version=\(Self.schemaVersion);")
    }

    private func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE;")
        do {
            try body()
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    @discardableResult
    private func execute(
        _ sql: String,
        bind: (OpaquePointer?) -> Void = { _ in }
    ) throws -> Int {
        guard let db else { throw SearchIndexStoreError.sqlite("database unavailable") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw sqliteError()
        }
        defer { sqlite3_finalize(statement) }
        bind(statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError() }
        return Int(sqlite3_changes(db))
    }

    private func query(
        _ sql: String,
        bind: (OpaquePointer?) -> Void = { _ in },
        row: (OpaquePointer?) throws -> Void
    ) throws {
        guard let db else { throw SearchIndexStoreError.sqlite("database unavailable") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw sqliteError()
        }
        defer { sqlite3_finalize(statement) }
        bind(statement)
        while sqlite3_step(statement) == SQLITE_ROW {
            try row(statement)
        }
    }

    private func exec(_ sql: String) throws {
        guard let db else { throw SearchIndexStoreError.sqlite("database unavailable") }
        var message: UnsafeMutablePointer<Int8>?
        guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
            let text = message.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(db))
            sqlite3_free(message)
            throw SearchIndexStoreError.sqlite(text)
        }
    }

    private func scalarInt(_ sql: String) throws -> Int {
        var value = 0
        try query(sql) { statement in
            value = Int(sqlite3_column_int64(statement, 0))
        }
        return value
    }

    private func sqliteError() -> SearchIndexStoreError {
        guard let db else { return .sqlite("database unavailable") }
        return .sqlite(String(cString: sqlite3_errmsg(db)))
    }

    private func bind(
        _ scope: SearchScanScope,
        to statement: OpaquePointer?,
        startingAt index: Int32 = 1
    ) {
        bindText(scope.accountID, to: statement, index: index)
        bindText(scope.providerUserKey, to: statement, index: index + 1)
        bindText(scope.libraryID, to: statement, index: index + 2)
    }

    private func bindText(_ value: String, to statement: OpaquePointer?, index: Int32) {
        sqlite3_bind_text(statement, index, value, -1, Self.transient)
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
        _ = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(
                statement,
                index,
                bytes.baseAddress,
                Int32(bytes.count),
                Self.transient
            )
        }
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

    private func bindOptionalDate(
        _ value: Date?,
        to statement: OpaquePointer?,
        index: Int32
    ) {
        if let value {
            sqlite3_bind_double(statement, index, value.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func columnText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let text = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: text)
    }

    private func columnBlob(_ statement: OpaquePointer?, _ index: Int32) -> Data? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0, let bytes = sqlite3_column_blob(statement, index) else {
            return Data()
        }
        return Data(bytes: bytes, count: count)
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
