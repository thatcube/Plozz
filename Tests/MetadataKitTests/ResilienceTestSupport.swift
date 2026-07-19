import Foundation
import CoreModels
@testable import MetadataKit

/// A thread-safe, movable clock for deterministic cooldown/expiry tests.
final class OutageTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Date
    init(_ value: Date = Date(timeIntervalSince1970: 1_000_000)) { _value = value }
    var value: Date {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
    func advance(_ seconds: TimeInterval) {
        lock.lock(); _value = _value.addingTimeInterval(seconds); lock.unlock()
    }
    /// A `@Sendable` closure view for injection.
    var nowClosure: @Sendable () -> Date { { [self] in value } }
}

/// A provider whose returned enrichment and health can be reprogrammed between calls,
/// recording how many times it actually ran (to prove breaker gating / cache hits).
final class ProgrammableProvider: MetadataEnrichmentProvider, @unchecked Sendable {
    let id: MetadataSource
    let capabilities: Set<MetadataCapability>
    let policy: ProviderPolicy

    private let lock = NSLock()
    private var _output: MetadataEnrichment
    private var _health: ProviderHealth
    private var _calls = 0

    init(
        id: MetadataSource,
        capabilities: Set<MetadataCapability> = [.canonicalText],
        version: Int = 1,
        output: MetadataEnrichment = MetadataEnrichment(),
        health: ProviderHealth = .empty
    ) {
        self.id = id
        self.capabilities = capabilities
        self.policy = ProviderPolicy(version: version)
        self._output = output
        self._health = health
    }

    func program(output: MetadataEnrichment, health: ProviderHealth) {
        lock.lock(); _output = output; _health = health; lock.unlock()
    }

    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }

    func enrich(_ query: MetadataQuery, missing: Set<MetadataField>) async -> MetadataEnrichment {
        await enrichReporting(query, missing: missing).enrichment
    }

    func enrichReporting(_ query: MetadataQuery, missing: Set<MetadataField>) async -> ProviderResponse {
        lock.lock()
        _calls += 1
        let out = _output
        let health = _health
        lock.unlock()
        return ProviderResponse(enrichment: out, health: health)
    }
}

func overviewEnrichment(_ text: String, _ source: MetadataSource) -> MetadataEnrichment {
    MetadataEnrichment(overview: SourcedValue(value: text, source: source))
}

func testQuery(_ type: ContentType = .movie, title: String = "Item") -> MetadataQuery {
    MetadataQuery(
        contentType: type, kind: .movie, title: title, alternateTitle: nil, year: 2020,
        seasonNumber: nil, episodeNumber: nil, animeIDs: AnimeIDs(), providerIDs: [:]
    )
}
