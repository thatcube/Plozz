import Foundation

public struct WatchlistDestinationID: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    public let rawValue: String

    public init?(rawValue: String) {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        self.rawValue = value
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let value = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid watchlist destination identifier."
            )
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum WatchlistBindingRequirement: String, Codable, Hashable, Sendable {
    case globalExternalIdentity
    case validatedLibraryCopy
}

public struct WatchlistReadCapability: Codable, Hashable, Sendable {
    public var isReadable: Bool
    public init(isReadable: Bool) { self.isReadable = isReadable }
}

public struct WatchlistWriteCapability: Codable, Hashable, Sendable {
    public var isWritable: Bool
    public var isRemovable: Bool
    public var bindingRequirement: WatchlistBindingRequirement

    public init(
        isWritable: Bool,
        isRemovable: Bool,
        bindingRequirement: WatchlistBindingRequirement
    ) {
        self.isWritable = isWritable
        self.isRemovable = isRemovable
        self.bindingRequirement = bindingRequirement
    }
}

public struct WatchlistDestinationCapabilities: Codable, Hashable, Sendable {
    public var read: WatchlistReadCapability
    public var write: WatchlistWriteCapability
    public var acceptedKinds: [MediaItemKind]
    public var globalIdentityNamespaces: [WatchlistExternalID.Namespace]

    public init(
        readable: Bool,
        writable: Bool,
        removable: Bool,
        acceptedKinds: [MediaItemKind] = [.movie, .series],
        bindingRequirement: WatchlistBindingRequirement,
        globalIdentityNamespaces: [WatchlistExternalID.Namespace] = []
    ) {
        read = WatchlistReadCapability(isReadable: readable)
        write = WatchlistWriteCapability(
            isWritable: writable,
            isRemovable: removable,
            bindingRequirement: bindingRequirement
        )
        self.acceptedKinds = Array(Set(
            acceptedKinds.filter { $0 == .movie || $0 == .series }
        )).sorted { $0.rawValue < $1.rawValue }
        self.globalIdentityNamespaces = Array(Set(globalIdentityNamespaces)).sorted()
    }

    public func accepts(_ kind: MediaItemKind) -> Bool {
        acceptedKinds.contains(kind)
    }
}

public struct WatchlistProviderBindingScope: Codable, Hashable, Sendable {
    public let providerKind: ProviderKind
    public let accountDescriptorID: String

    public init(providerKind: ProviderKind, accountDescriptorID: String) {
        self.providerKind = providerKind
        self.accountDescriptorID = accountDescriptorID
    }
}

public struct WatchlistDestinationRouting: Codable, Hashable, Sendable {
    public let globalIdentityNamespaces: [WatchlistExternalID.Namespace]
    public let validatedBindingScopes: [WatchlistProviderBindingScope]

    public init(
        globalIdentityNamespaces: [WatchlistExternalID.Namespace] = [],
        validatedBindingScopes: [WatchlistProviderBindingScope] = []
    ) {
        self.globalIdentityNamespaces = Array(
            Set(globalIdentityNamespaces)
        ).sorted()
        self.validatedBindingScopes = Array(
            Set(validatedBindingScopes)
        ).sorted {
            if $0.providerKind.rawValue != $1.providerKind.rawValue {
                return $0.providerKind.rawValue < $1.providerKind.rawValue
            }
            return $0.accountDescriptorID < $1.accountDescriptorID
        }
    }
}

public struct WatchlistExternalID: Codable, Hashable, Sendable, Comparable {
    public enum Namespace: String, Codable, Hashable, Sendable, Comparable {
        case imdb
        case tmdb
        case tvdb
        case trakt
        case plex
        // The anime catalogues. A universal identity that stops at the five
        // namespaces the film/TV trackers happen to use is not universal — the
        // rest of the app has carried AniList, MyAnimeList and AniDB ids all
        // along, and this layer was quietly dropping them, which is precisely
        // what made an AniList or MAL destination impossible to write.
        case aniList
        case myAnimeList
        case aniDB

        public static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    public let namespace: Namespace
    public let value: String

    public init?(namespace: Namespace, value: String) {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return nil }
        self.namespace = namespace
        self.value = value
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.namespace != rhs.namespace { return lhs.namespace < rhs.namespace }
        return lhs.value < rhs.value
    }
}

public struct WatchlistMutationTarget: Codable, Hashable, Sendable {
    public let aliasID: MediaAliasID
    public let kind: MediaItemKind
    public var externalIDs: [WatchlistExternalID]
    public var validatedBindings: [MediaAliasProviderBindingKey]

    public init?(
        aliasID: MediaAliasID,
        kind: MediaItemKind,
        externalIDs: [WatchlistExternalID] = [],
        validatedBindings: [MediaAliasProviderBindingKey] = []
    ) {
        guard kind == .movie || kind == .series else { return nil }
        self.aliasID = aliasID
        self.kind = kind
        self.externalIDs = Array(Set(externalIDs.compactMap {
            WatchlistExternalID(namespace: $0.namespace, value: $0.value)
        })).sorted()
        self.validatedBindings = Array(Set(validatedBindings)).sorted()
    }

    public init?(aliasID: MediaAliasID, item: MediaItem, validatedBindings: [MediaAliasProviderBindingKey] = []) {
        var ids: [WatchlistExternalID] = []
        if let value = item.providerID(.imdb) {
            ids.append(WatchlistExternalID(namespace: .imdb, value: value)!)
        }
        if let value = item.providerID(.tmdb) {
            ids.append(WatchlistExternalID(namespace: .tmdb, value: value)!)
        }
        if let value = item.providerID(.tvdb) {
            ids.append(WatchlistExternalID(namespace: .tvdb, value: value)!)
        }
        if let value = item.providerIDs.first(where: {
            $0.key.caseInsensitiveCompare("Trakt") == .orderedSame
        })?.value, let id = WatchlistExternalID(namespace: .trakt, value: value) {
            ids.append(id)
        }
        if let value = item.providerIDs["PlexGuid"],
           let id = WatchlistExternalID(namespace: .plex, value: value) {
            ids.append(id)
        }
        // Anime catalogues. Series-scoped spellings are accepted as a fallback
        // because a show's own id is often only recorded on the series row.
        for (namespace, seriesNamespace, target) in [
            (ProviderIDNamespace.aniList, ProviderIDNamespace.seriesAniList, WatchlistExternalID.Namespace.aniList),
            (ProviderIDNamespace.myAnimeList, ProviderIDNamespace.seriesMal, WatchlistExternalID.Namespace.myAnimeList),
            (ProviderIDNamespace.aniDB, ProviderIDNamespace.seriesAniDB, WatchlistExternalID.Namespace.aniDB),
        ] {
            guard let value = item.providerID(namespace)
                    ?? item.providerID(seriesNamespace),
                  let id = WatchlistExternalID(namespace: target, value: value)
            else { continue }
            ids.append(id)
        }
        self.init(
            aliasID: aliasID,
            kind: item.kind,
            externalIDs: ids,
            validatedBindings: validatedBindings
        )
    }

    public init?(aliasID: MediaAliasID, aliasRecord: MediaAliasRecord) {
        let ids = aliasRecord.strongEvidence.compactMap { evidence -> WatchlistExternalID? in
            let namespace: WatchlistExternalID.Namespace
            switch evidence.namespace {
            case .imdb: namespace = .imdb
            case .tmdb: namespace = .tmdb
            case .tvdb: namespace = .tvdb
            case .aniList, .seriesAniList: namespace = .aniList
            case .myAnimeList, .seriesMal: namespace = .myAnimeList
            case .aniDB, .seriesAniDB: namespace = .aniDB
            default: return nil
            }
            return WatchlistExternalID(namespace: namespace, value: evidence.value)
        }
        self.init(
            aliasID: aliasID,
            kind: aliasRecord.kind,
            externalIDs: ids,
            validatedBindings: Array(aliasRecord.locallyValidatedBindings)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case aliasID, kind, externalIDs, validatedBindings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let value = WatchlistMutationTarget(
            aliasID: try container.decode(MediaAliasID.self, forKey: .aliasID),
            kind: try container.decode(MediaItemKind.self, forKey: .kind),
            externalIDs: try container.decodeIfPresent(
                [WatchlistExternalID].self,
                forKey: .externalIDs
            ) ?? [],
            validatedBindings: try container.decodeIfPresent(
                [MediaAliasProviderBindingKey].self,
                forKey: .validatedBindings
            ) ?? []
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Watchlist targets support movies and series only."
            )
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(aliasID, forKey: .aliasID)
        try container.encode(kind, forKey: .kind)
        try container.encode(externalIDs, forKey: .externalIDs)
        try container.encode(validatedBindings, forKey: .validatedBindings)
    }
    /// A stable, cross-launch fingerprint of the parts of this target that can
    /// change what a write would do. Deliberately **not** `hashValue`, which
    /// Swift randomizes per process and must never be persisted.
    public var identityFingerprint: String {
        kind.rawValue + "#" + externalIDs
            .map { "\($0.namespace.rawValue):\($0.value)" }
            .sorted()
            .joined(separator: "|")
    }

}

/// Destination-private address. Its opaque value may be a provider item ID and
/// must never be included in diagnostics.
public struct WatchlistDestinationBinding: Codable, Hashable, Sendable {
    public let destinationID: WatchlistDestinationID
    public let opaqueValues: [String]
    public var opaqueValue: String { opaqueValues[0] }

    public init?(destinationID: WatchlistDestinationID, opaqueValue: String) {
        self.init(destinationID: destinationID, opaqueValues: [opaqueValue])
    }

    public init?(
        destinationID: WatchlistDestinationID,
        opaqueValues: [String]
    ) {
        let values = Array(Set(opaqueValues.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })).sorted()
        guard !values.isEmpty else { return nil }
        self.destinationID = destinationID
        self.opaqueValues = values
    }

    private enum CodingKeys: String, CodingKey {
        case destinationID, opaqueValues
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let value = WatchlistDestinationBinding(
            destinationID: try container.decode(
                WatchlistDestinationID.self,
                forKey: .destinationID
            ),
            opaqueValues: try container.decode(
                [String].self,
                forKey: .opaqueValues
            )
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .opaqueValues,
                in: container,
                debugDescription: "Watchlist binding has no valid opaque values."
            )
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(destinationID, forKey: .destinationID)
        try container.encode(opaqueValues, forKey: .opaqueValues)
    }
}

public struct WatchlistDestinationEntry: Codable, Hashable, Sendable {
    public let kind: MediaItemKind
    public let externalIDs: [WatchlistExternalID]
    public let binding: WatchlistDestinationBinding
    public let corroboratedProviderBinding: MediaAliasProviderBindingKey?
    public let presentation: MediaAliasPresentation?

    public init?(
        kind: MediaItemKind,
        externalIDs: [WatchlistExternalID],
        binding: WatchlistDestinationBinding,
        corroboratedProviderBinding: MediaAliasProviderBindingKey? = nil,
        presentation: MediaAliasPresentation? = nil
    ) {
        guard kind == .movie || kind == .series else { return nil }
        self.kind = kind
        self.externalIDs = Array(Set(externalIDs)).sorted()
        self.binding = binding
        self.corroboratedProviderBinding = corroboratedProviderBinding
        self.presentation = presentation?.sanitizedForSync()
    }

    /// Alias-ledger evidence produced by a successful destination read. Provider
    /// bindings are locally validated because the destination itself observed the
    /// item; synced hints never enter through this path.
    public var mediaAliasEvidence: MediaAliasEvidence? {
        let strong = externalIDs.compactMap {
            externalID -> MediaAliasStrongEvidence? in
            let namespace: ProviderIDNamespace
            switch externalID.namespace {
            case .imdb: namespace = .imdb
            case .tmdb: namespace = .tmdb
            case .tvdb: namespace = .tvdb
            case .aniList: namespace = .aniList
            case .myAnimeList: namespace = .myAnimeList
            case .aniDB: namespace = .aniDB
            // Trakt and Plex ids identify a title only WITHIN those services, so
            // they are not evidence of what the title is.
            case .trakt, .plex: return nil
            }
            return MediaAliasStrongEvidence(
                kind: kind,
                namespace: namespace,
                value: externalID.value
            )
        }
        let globalEvidence = externalIDs.map {
            MediaIdentity.external(
                source: "\($0.namespace.rawValue):\(kind.rawValue)",
                value: $0.value
            )
        }
        let hints = corroboratedProviderBinding.map {
            [
                MediaAliasProviderBindingHint(
                    binding: $0,
                    globalEvidence: globalEvidence,
                    sourceValidation: .observedBySource,
                    observedAt: Date()
                )
            ]
        } ?? []
        return MediaAliasEvidence(
            kind: kind,
            strong: strong,
            weak: presentation.flatMap {
                MediaAliasWeakEvidence(
                    kind: kind,
                    title: $0.title,
                    year: $0.year
                )
            },
            presentation: presentation,
            bindingHints: hints,
            locallyValidatedBindings: Set(
                corroboratedProviderBinding.map { [$0] } ?? []
            )
        )
    }
}

public enum WatchlistDestinationError: Error, Equatable, Sendable {
    case authenticationRequired
    case rateLimited(retryAfter: TimeInterval?)
    case transient
    case unsupportedIdentity
    case permanent
}

public protocol WatchlistDestination: Sendable {
    var id: WatchlistDestinationID { get }
    var capabilities: WatchlistDestinationCapabilities { get }
    var routing: WatchlistDestinationRouting { get }
    func fetchEntries() async throws -> [WatchlistDestinationEntry]
    func resolve(_ target: WatchlistMutationTarget) async throws -> WatchlistDestinationBinding?
    func apply(
        _ desiredState: WatchlistDesiredState,
        to binding: WatchlistDestinationBinding
    ) async throws
}

/// A destination that can also say which item in the viewer's own library a
/// watchlist entry IS.
///
/// Separate from `WatchlistDestination` because only a destination backed by a
/// media server can answer it — a tracker knows what you want to watch, not what
/// you own. Asking the server directly is what removes the dependency on a
/// complete, current, successfully-published client-side catalogue index just to
/// decide whether a title is in the library.
public protocol WatchlistLibraryResolving: WatchlistDestination {
    /// The owned copy of `entry`, or `nil` when this server doesn't have it.
    func resolveLibraryCopy(
        for entry: WatchlistDestinationEntry
    ) async -> MediaSourceRef?
}

public extension WatchlistDestination {
    var routing: WatchlistDestinationRouting {
        WatchlistDestinationRouting(
            globalIdentityNamespaces:
                capabilities.globalIdentityNamespaces
        )
    }
}

public struct WatchlistDestinationRegistry: Sendable {
    private let destinationsByID: [WatchlistDestinationID: any WatchlistDestination]
    private let destinationIDsByGlobalNamespace:
        [WatchlistExternalID.Namespace: Set<WatchlistDestinationID>]
    private let destinationIDsByBindingScope:
        [WatchlistProviderBindingScope: Set<WatchlistDestinationID>]

    public init(_ destinations: [any WatchlistDestination]) {
        var values: [WatchlistDestinationID: any WatchlistDestination] = [:]
        for destination in destinations {
            values[destination.id] = destination
        }
        destinationsByID = values
        var globals:
            [WatchlistExternalID.Namespace: Set<WatchlistDestinationID>] = [:]
        var bindings:
            [WatchlistProviderBindingScope: Set<WatchlistDestinationID>] = [:]
        for destination in values.values {
            for namespace in destination.routing.globalIdentityNamespaces {
                globals[namespace, default: []].insert(destination.id)
            }
            for scope in destination.routing.validatedBindingScopes {
                bindings[scope, default: []].insert(destination.id)
            }
        }
        destinationIDsByGlobalNamespace = globals
        destinationIDsByBindingScope = bindings
    }

    public var destinations: [any WatchlistDestination] {
        destinationsByID.keys.sorted().compactMap { destinationsByID[$0] }
    }

    public subscript(id: WatchlistDestinationID) -> (any WatchlistDestination)? {
        destinationsByID[id]
    }

    public func destinationIDs(
        for target: WatchlistMutationTarget
    ) -> Set<WatchlistDestinationID> {
        var result: Set<WatchlistDestinationID> = []
        for externalID in target.externalIDs {
            result.formUnion(
                destinationIDsByGlobalNamespace[externalID.namespace] ?? []
            )
        }
        for binding in target.validatedBindings {
            result.formUnion(destinationIDsByBindingScope[
                WatchlistProviderBindingScope(
                    providerKind: binding.providerKind,
                    accountDescriptorID: binding.accountDescriptorID
                )
            ] ?? [])
        }
        return result.filter {
            guard let destination = destinationsByID[$0] else { return false }
            return destination.capabilities.accepts(target.kind)
                && destination.capabilities.write.isWritable
        }
    }
}
