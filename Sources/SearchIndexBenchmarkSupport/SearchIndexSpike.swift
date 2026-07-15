#if DEBUG && canImport(NaturalLanguage)
import Foundation
import Darwin
import CoreModels
import SearchIndexKit

public struct SearchIndexQualityResult: Sendable {
    public let format: VectorStorageFormat
    public let topOneRate: Double
    public let topFiveRate: Double
}

public struct SearchIndexScaleResult: Sendable {
    public let documentCount: Int
    public let vectorBytes: Int
    public let elapsedSeconds: Double
    public let residentMemoryIncrease: UInt64
}

public struct SearchIndexSQLiteScaleResult: Sendable {
    public let documentCount: Int
    public let buildSeconds: Double
    public let warmSeconds: Double
    public let querySeconds: Double
    public let filteredQuerySeconds: Double
    public let databaseBytes: UInt64
}

public struct SearchIndexSpikeReport: Sendable {
    public let model: EmbeddingModelDescriptor
    public let languageAvailability: [String]
    public let embeddingDocumentsPerSecond: Double
    public let quality: [SearchIndexQualityResult]
    public let scale: [SearchIndexScaleResult]
    public let sqliteScale: [SearchIndexSQLiteScaleResult]

    public var lines: [String] {
        var result = [
            "SEARCH_INDEX_MODEL language=\(model.language.rawValue) " +
                "revision=\(model.revision) dimension=\(model.dimension)"
        ]
        result.append(contentsOf: quality.map {
            "SEARCH_INDEX_QUALITY format=\($0.format.rawValue) " +
                "top1=\($0.topOneRate) top5=\($0.topFiveRate)"
        })
        result.append("SEARCH_INDEX_LANGUAGES \(languageAvailability.joined(separator: " "))")
        result.append("SEARCH_INDEX_EMBEDDING docsPerSecond=\(embeddingDocumentsPerSecond)")
        result.append(contentsOf: scale.map {
            "SEARCH_INDEX_SPIKE count=\($0.documentCount) " +
                "vectorBytes=\($0.vectorBytes) elapsed=\($0.elapsedSeconds)s " +
                "residentIncrease=\($0.residentMemoryIncrease)"
        })
        result.append(contentsOf: sqliteScale.map {
            "SEARCH_INDEX_SQLITE count=\($0.documentCount) " +
                "build=\($0.buildSeconds)s warm=\($0.warmSeconds)s " +
                "query=\($0.querySeconds)s filtered=\($0.filteredQuerySeconds)s " +
                "databaseBytes=\($0.databaseBytes)"
        })
        return result
    }
}

public enum SearchIndexSpikeError: Error {
    case englishModelUnavailable
    case embeddingFailed(String)
}

public struct SearchIndexSpikeRunner: Sendable {
    public init() {}

    public func run(
        scaleCounts: [Int] = [10_000, 50_000, 100_000],
        sqliteScaleCounts: [Int] = []
    ) async throws
        -> SearchIndexSpikeReport {
        let provider = AppleSentenceEmbeddingProvider()
        guard let descriptor = await provider.descriptor(for: .english) else {
            throw SearchIndexSpikeError.englishModelUnavailable
        }

        let documents = Self.documents
        var rawCandidates: [(String, [Float])] = []
        for (id, text) in documents {
            guard let vector = await provider.vector(for: text, using: descriptor) else {
                throw SearchIndexSpikeError.embeddingFailed(id)
            }
            rawCandidates.append((id, try VectorMath.normalized(vector)))
        }

        var quality: [SearchIndexQualityResult] = []
        for format in VectorStorageFormat.allCases {
            let candidates = try rawCandidates.map { id, vector in
                SemanticCandidate(
                    sourceKey: id,
                    vectors: [
                        try VectorCodec.decode(
                            VectorCodec.encode(vector, format: format),
                            format: format,
                            dimension: descriptor.dimension
                        )
                    ]
                )
            }
            var topOneCount = 0
            var topFiveCount = 0
            let textByID = Dictionary(uniqueKeysWithValues: documents)
            for (query, expected) in Self.queries {
                guard let vector = await provider.vector(for: query, using: descriptor) else {
                    throw SearchIndexSpikeError.embeddingFailed(query)
                }
                let semanticMatches = try await SemanticRanker.topMatches(
                    query: try VectorMath.normalized(vector),
                    candidates: candidates,
                    limit: documents.count
                )
                let matches = semanticMatches
                    .map { match in
                        (
                            sourceKey: match.sourceKey,
                            score: match.score + HybridRankingPolicy().lexicalBoost(
                                query: query,
                                title: match.sourceKey,
                                metadataText: textByID[match.sourceKey] ?? ""
                            )
                        )
                    }
                    .sorted {
                        if $0.score != $1.score { return $0.score > $1.score }
                        return $0.sourceKey < $1.sourceKey
                    }
                    .prefix(5)
                if matches.first?.sourceKey == expected {
                    topOneCount += 1
                }
                if matches.contains(where: { $0.sourceKey == expected }) {
                    topFiveCount += 1
                }
            }
            quality.append(SearchIndexQualityResult(
                format: format,
                topOneRate: Double(topOneCount) / Double(Self.queries.count),
                topFiveRate: Double(topFiveCount) / Double(Self.queries.count)
            ))
        }

        let languages: [EmbeddingLanguage] = [
            .english, .spanish, .french, .german, .italian, .portuguese,
            .simplifiedChinese, EmbeddingLanguage(rawValue: "ar"),
            EmbeddingLanguage(rawValue: "ko")
        ]
        var languageAvailability: [String] = []
        for language in languages {
            let available = await provider.descriptor(for: language)
            languageAvailability.append(
                "\(language.rawValue)=\(available.map { "r\($0.revision)/\($0.dimension)" } ?? "nil")"
            )
        }

        let embeddingSampleCount = 100
        let embeddingClock = ContinuousClock()
        let embeddingStart = embeddingClock.now
        for index in 0..<embeddingSampleCount {
            guard await provider.vector(
                for: "Synthetic episode \(index) where a family solves a neighborhood mystery.",
                using: descriptor
            ) != nil else {
                throw SearchIndexSpikeError.embeddingFailed("throughput-\(index)")
            }
        }
        let embeddingSeconds = Self.seconds(
            embeddingStart.duration(to: embeddingClock.now)
        )
        let embeddingDocumentsPerSecond = Double(embeddingSampleCount) /
            max(embeddingSeconds, 0.000_001)

        let dimension = descriptor.dimension
        let query = try VectorMath.normalized(
            (0..<dimension).map { Float(($0 % 17) + 1) }
        )
        var scale: [SearchIndexScaleResult] = []
        for count in scaleCounts {
            let baselineMemory = Self.residentMemoryBytes()
            var candidates: [SemanticCandidate] = []
            candidates.reserveCapacity(count)
            for item in 0..<count {
                let vector = try VectorMath.normalized(
                    (0..<dimension).map { component in
                        Float(((item &* 31) &+ (component &* 17)) % 101) - 50
                    }
                )
                candidates.append(SemanticCandidate(
                    sourceKey: String(item),
                    vectors: [vector]
                ))
            }
            let clock = ContinuousClock()
            let start = clock.now
            _ = try await SemanticRanker.topMatches(
                query: query,
                candidates: candidates,
                limit: 20
            )
            let seconds = Self.seconds(start.duration(to: clock.now))
            let residentMemory = Self.residentMemoryBytes()
            scale.append(SearchIndexScaleResult(
                documentCount: count,
                vectorBytes: count * dimension * MemoryLayout<Float>.stride,
                elapsedSeconds: seconds,
                residentMemoryIncrease: residentMemory >= baselineMemory
                    ? residentMemory - baselineMemory
                    : 0
            ))
        }

        var sqliteScale: [SearchIndexSQLiteScaleResult] = []
        for count in sqliteScaleCounts {
            sqliteScale.append(
                try await sqliteScaleResult(
                    count: count,
                    descriptor: descriptor
                )
            )
        }

        return SearchIndexSpikeReport(
            model: descriptor,
            languageAvailability: languageAvailability,
            embeddingDocumentsPerSecond: embeddingDocumentsPerSecond,
            quality: quality,
            scale: scale,
            sqliteScale: sqliteScale
        )
    }

    private func sqliteScaleResult(
        count: Int,
        descriptor: EmbeddingModelDescriptor
    ) async throws -> SearchIndexSQLiteScaleResult {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plozz-search-spike-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = LocalSearchIndex(
            scopeKey: "spike",
            directory: directory,
            storageFormat: .float16
        )
        let token = await store.activateWriteGeneration()
        let builder = SearchDocumentBuilder()
        let clock = ContinuousClock()
        let buildStart = clock.now
        let batchSize = 200
        for start in stride(from: 0, to: count, by: batchSize) {
            let end = min(start + batchSize, count)
            let writes = try (start..<end).map { index -> SearchIndexWrite in
                let kind: MediaItemKind = index.isMultiple(of: 2) ? .episode : .movie
                let item = MediaItem(
                    id: String(index),
                    title: "\(kind == .episode ? "Episode" : "Movie") \(index)",
                    kind: kind,
                    overview: "Synthetic \(kind.rawValue) \(index) about a family mystery.",
                    parentTitle: kind == .episode ? "Synthetic Show" : nil,
                    seasonNumber: kind == .episode ? index / 20 : nil,
                    episodeNumber: kind == .episode ? index % 20 : nil,
                    libraryID: "mixed"
                )
                let document = builder.document(
                    for: item,
                    accountID: "account",
                    providerUserKey: "user"
                )
                let vector = try VectorMath.normalized(
                    (0..<descriptor.dimension).map { component in
                        Float(((index &* 31) &+ (component &* 17)) % 101) - 50
                    }
                )
                return SearchIndexWrite(
                    document: document,
                    embeddings: [
                        SearchDocumentEmbedding(
                            segment: 0,
                            descriptor: descriptor,
                            vector: vector
                        )
                    ]
                )
            }
            try await store.upsert(
                writes,
                scanGeneration: 1,
                writeToken: token
            )
            await Task.yield()
        }
        let buildSeconds = Self.seconds(buildStart.duration(to: clock.now))

        let queryVector = try VectorMath.normalized(
            (0..<descriptor.dimension).map { Float(($0 % 17) + 1) }
        )
        let warmStart = clock.now
        _ = try await store.warm(descriptor: descriptor)
        _ = try await store.warm(descriptor: descriptor, kind: .episode)
        let warmSeconds = Self.seconds(warmStart.duration(to: clock.now))
        let queryStart = clock.now
        _ = try await store.search(LocalSearchRequest(
            queryText: "a family mystery",
            queryVector: queryVector,
            descriptor: descriptor,
            limit: 20
        ))
        let querySeconds = Self.seconds(queryStart.duration(to: clock.now))
        let filteredStart = clock.now
        _ = try await store.search(LocalSearchRequest(
            queryText: "an episode about a family mystery",
            queryVector: queryVector,
            descriptor: descriptor,
            intent: LocalSearchIntent(kinds: [.episode]),
            limit: 20
        ))
        let filteredQuerySeconds = Self.seconds(
            filteredStart.duration(to: clock.now)
        )
        let databaseBytes = (try? FileManager.default.attributesOfItem(
            atPath: store.databaseURL.path
        )[.size] as? NSNumber)?.uint64Value ?? 0
        return SearchIndexSQLiteScaleResult(
            documentCount: count,
            buildSeconds: buildSeconds,
            warmSeconds: warmSeconds,
            querySeconds: querySeconds,
            filteredQuerySeconds: filteredQuerySeconds,
            databaseBytes: databaseBytes
        )
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) +
            Double(components.attoseconds) / 1_000_000_000_000_000_000
    }

    private static func residentMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.size /
                MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(
                to: integer_t.self,
                capacity: Int(count)
            ) { rebound in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    rebound,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(info.resident_size)
    }

    private static let documents: [(String, String)] = [
        ("restaurant", "A group of friends waits all night for a table at a Chinese restaurant."),
        ("time-loop", "The crew keeps reliving the same day until they repair a temporal anomaly."),
        ("spaceship", "Engine failure leaves a damaged spaceship drifting beyond a distant star."),
        ("wedding", "Two families clash while preparing for an elaborate wedding."),
        ("storm", "A coastal village shelters together when a powerful storm arrives."),
        ("museum-heist", "A retired detective prevents thieves from stealing a painting during a museum gala."),
        ("missing-dog", "Two siblings search the neighborhood for their missing dog before sunset."),
        ("election", "A small-town teacher unexpectedly runs for mayor against a longtime incumbent."),
        ("haunted-hotel", "Guests discover that an abandoned seaside hotel is haunted by its former owner."),
        ("cooking-contest", "Amateur chefs compete to recreate a difficult family recipe."),
        ("submarine", "A submarine crew loses contact with the surface while exploring a deep trench."),
        ("desert-roadtrip", "Old friends cross the desert in a broken camper on their way to a reunion."),
        ("school-play", "Students race to save their school play after the lead actor loses their voice."),
        ("radio-blackout", "A radio host guides a city through a blackout using an emergency broadcast."),
        ("mountain-rescue", "Volunteer climbers attempt a dangerous rescue during an avalanche."),
        ("library-mystery", "A librarian follows coded notes hidden inside returned books."),
        ("robot-child", "A family teaches a newly activated household robot how to care for a child."),
        ("snow-train", "Passengers are stranded aboard a train when heavy snow blocks the mountain pass."),
        ("garden-contest", "Neighbors sabotage each other before an annual garden competition."),
        ("lighthouse", "A lighthouse keeper investigates strange signals coming from an empty island.")
    ]

    private static let queries: [(String, String)] = [
        ("the episode where everybody waits at a Chinese restaurant", "restaurant"),
        ("the crew repeats one day over and over", "time-loop"),
        ("people take shelter from dangerous weather by the ocean", "storm"),
        ("someone finds secret messages in library books", "library-mystery"),
        ("a broadcaster helps people when the power goes out", "radio-blackout"),
        ("children look everywhere for their lost pet", "missing-dog"),
        ("a dangerous mission to save climbers after an avalanche", "mountain-rescue"),
        ("thieves try to take artwork during a fancy event", "museum-heist"),
        ("travelers cannot move because snow traps their train", "snow-train"),
        ("a machine learns how to look after a young person", "robot-child")
    ]
}
#endif
