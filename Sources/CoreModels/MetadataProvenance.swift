import Foundation

/// A stable, open identifier for the origin of one metadata value.
///
/// This is a raw-string value rather than an enum so records written by a newer
/// Plozz version remain decodable by older builds that do not know the source yet.
public struct MetadataSource: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let server = Self(rawValue: "server")
    public static let filename = Self(rawValue: "filename")
    public static let localNFO = Self(rawValue: "localNFO")
    public static let embedded = Self(rawValue: "embedded")
    public static let localArtwork = Self(rawValue: "localArtwork")
    public static let generated = Self(rawValue: "generated")
    public static let tvdb = Self(rawValue: "tvdb")
    public static let tmdb = Self(rawValue: "tmdb")
    public static let anilist = Self(rawValue: "anilist")
    public static let tvmaze = Self(rawValue: "tvmaze")
    public static let wikidata = Self(rawValue: "wikidata")
    public static let wikipedia = Self(rawValue: "wikipedia")
    public static let kitsu = Self(rawValue: "kitsu")
    public static let mal = Self(rawValue: "mal")
    public static let legacyUnknown = Self(rawValue: "legacyUnknown")
}

/// A stable, open identifier for a metadata field.
public struct MetadataField: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let title = Self(rawValue: "title")
    public static let overview = Self(rawValue: "overview")
    public static let genres = Self(rawValue: "genres")
    public static let runtime = Self(rawValue: "runtime")
    public static let posterURL = Self(rawValue: "posterURL")
    public static let backdropURL = Self(rawValue: "backdropURL")
    public static let logoURL = Self(rawValue: "logoURL")
    public static let homeHero = Self(rawValue: "homeHero")
    public static let detailBackdrop = Self(rawValue: "detailBackdrop")
    public static let episodeThumbnail = Self(rawValue: "episodeThumbnail")

    public static func providerID(_ namespace: String) -> Self {
        Self(rawValue: "providerID.\(namespace.lowercased())")
    }
}

/// Attribution retained for one field, including an optional stable page/API URL.
public struct MetadataAttribution: Codable, Hashable, Sendable {
    public var source: MetadataSource
    public var sourceURL: URL?

    public init(source: MetadataSource, sourceURL: URL? = nil) {
        self.source = source
        self.sourceURL = sourceURL
    }
}

/// A value paired with its exact origin.
public struct SourcedValue<Value: Sendable>: Sendable {
    public var value: Value
    public var source: MetadataSource
    public var sourceURL: URL?

    public init(value: Value, source: MetadataSource, sourceURL: URL? = nil) {
        self.value = value
        self.source = source
        self.sourceURL = sourceURL
    }

    public var attribution: MetadataAttribution {
        MetadataAttribution(source: source, sourceURL: sourceURL)
    }

    public func map<Mapped: Sendable>(
        _ transform: (Value) throws -> Mapped
    ) rethrows -> SourcedValue<Mapped> {
        SourcedValue<Mapped>(
            value: try transform(value),
            source: source,
            sourceURL: sourceURL
        )
    }
}

extension SourcedValue: Equatable where Value: Equatable {}
extension SourcedValue: Hashable where Value: Hashable {}
extension SourcedValue: Codable where Value: Codable {}

/// Field-level attribution for a flattened domain value such as ``MediaItem``.
public struct MetadataProvenance: Codable, Hashable, Sendable {
    private var storage: [MetadataField: MetadataAttribution]

    public init(_ storage: [MetadataField: MetadataAttribution] = [:]) {
        self.storage = storage
    }

    public var isEmpty: Bool { storage.isEmpty }

    public subscript(field: MetadataField) -> MetadataAttribution? {
        get { storage[field] }
        set { storage[field] = newValue }
    }

    public mutating func set<Value>(_ sourced: SourcedValue<Value>?, for field: MetadataField) {
        guard let sourced else { return }
        storage[field] = sourced.attribution
    }

    public mutating func fillMissing(
        _ attribution: MetadataAttribution,
        for fields: some Sequence<MetadataField>
    ) {
        for field in fields where storage[field] == nil {
            storage[field] = attribution
        }
    }

    public mutating func mergeMissing(from other: MetadataProvenance) {
        for (field, attribution) in other.storage where storage[field] == nil {
            storage[field] = attribution
        }
    }

    public mutating func mergeReplacing(from other: MetadataProvenance) {
        for (field, attribution) in other.storage {
            storage[field] = attribution
        }
    }

    private struct DynamicCodingKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }

        init?(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            return nil
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        var decoded: [MetadataField: MetadataAttribution] = [:]
        for key in container.allKeys {
            guard let attribution = try? container.decode(MetadataAttribution.self, forKey: key) else {
                continue
            }
            decoded[MetadataField(rawValue: key.stringValue)] = attribution
        }
        storage = decoded
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        for (field, attribution) in storage {
            guard let key = DynamicCodingKey(stringValue: field.rawValue) else { continue }
            try container.encode(attribution, forKey: key)
        }
    }

    public func hash(into hasher: inout Hasher) {
        for (field, attribution) in storage.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            hasher.combine(field)
            hasher.combine(attribution)
        }
    }
}

/// Open context key used by data-driven source-priority tables.
public struct MetadataPriorityContext: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct MetadataPriorityRule: Codable, Hashable, Sendable {
    public var context: MetadataPriorityContext
    public var field: MetadataField
    public var sources: [MetadataSource]

    public init(
        context: MetadataPriorityContext,
        field: MetadataField,
        sources: [MetadataSource]
    ) {
        self.context = context
        self.field = field
        self.sources = sources
    }
}

/// Ordered source rules represented as values so later settings can replace policy
/// without rewriting provider-routing branches.
public struct MetadataPriorityPolicy: Codable, Hashable, Sendable {
    public var rules: [MetadataPriorityRule]

    public init(rules: [MetadataPriorityRule]) {
        self.rules = rules
    }

    public func sources(
        for field: MetadataField,
        context: MetadataPriorityContext
    ) -> [MetadataSource] {
        rules.first { $0.field == field && $0.context == context }?.sources ?? []
    }
}
