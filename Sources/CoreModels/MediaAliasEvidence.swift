import Foundation

public struct MediaAliasStrongEvidence: Codable, Hashable, Sendable, Comparable {
    public let kind: MediaItemKind
    public let namespace: ProviderIDNamespace
    public let value: String

    public init?(kind: MediaItemKind, namespace: ProviderIDNamespace, value: String) {
        guard kind == .movie || kind == .series else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        self.kind = kind
        self.namespace = namespace
        self.value = normalized
    }

    public var mediaIdentity: MediaIdentity {
        .external(source: "\(namespace.rawValue):\(kind.rawValue)", value: value)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.kind.rawValue != rhs.kind.rawValue {
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
        if lhs.namespace.rawValue != rhs.namespace.rawValue {
            return lhs.namespace.rawValue < rhs.namespace.rawValue
        }
        return lhs.value < rhs.value
    }
}

public struct MediaAliasWeakEvidence: Codable, Hashable, Sendable, Comparable {
    public let kind: MediaItemKind
    public let normalizedTitle: String
    public let year: Int

    public init?(kind: MediaItemKind, title: String, year: Int?) {
        guard kind == .movie || kind == .series, let year else { return nil }
        let normalizedTitle = MediaItemIdentity.normalizedTitle(title)
        guard !normalizedTitle.isEmpty else { return nil }
        self.kind = kind
        self.normalizedTitle = normalizedTitle
        self.year = year
    }

    public init?(kind: MediaItemKind, normalizedTitle: String, year: Int) {
        self.init(kind: kind, title: normalizedTitle, year: year)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.kind.rawValue != rhs.kind.rawValue {
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
        if lhs.normalizedTitle != rhs.normalizedTitle {
            return lhs.normalizedTitle < rhs.normalizedTitle
        }
        return lhs.year < rhs.year
    }
}

public struct MediaAliasPresentation: Codable, Hashable, Sendable {
    public var title: String
    public var year: Int?
    public var artworkURL: String?
    public var backdropURL: String?

    public init(
        title: String,
        year: Int? = nil,
        artworkURL: String? = nil,
        backdropURL: String? = nil
    ) {
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.year = year
        self.artworkURL = SyncURLSanitizer.sanitize(string: artworkURL)
        self.backdropURL = SyncURLSanitizer.sanitize(string: backdropURL)
    }

    public func sanitizedForSync() -> Self {
        Self(
            title: title,
            year: year,
            artworkURL: artworkURL,
            backdropURL: backdropURL
        )
    }
}

public struct MediaAliasProviderBindingKey: Codable, Hashable, Sendable, Comparable {
    public let providerKind: ProviderKind
    public let accountDescriptorID: String
    public let providerItemID: String

    public init?(
        providerKind: ProviderKind,
        accountDescriptorID: String,
        providerItemID: String
    ) {
        let account = accountDescriptorID.trimmingCharacters(in: .whitespacesAndNewlines)
        let item = providerItemID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !account.isEmpty, !item.isEmpty else { return nil }
        self.providerKind = providerKind
        self.accountDescriptorID = account
        self.providerItemID = item
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.providerKind.rawValue != rhs.providerKind.rawValue {
            return lhs.providerKind.rawValue < rhs.providerKind.rawValue
        }
        if lhs.accountDescriptorID != rhs.accountDescriptorID {
            return lhs.accountDescriptorID < rhs.accountDescriptorID
        }
        return lhs.providerItemID < rhs.providerItemID
    }

    public var isPrivacySafeForSync: Bool {
        let accountIsOpaqueUUID = UUID(uuidString: accountDescriptorID) != nil
        let accountParts = accountDescriptorID.split(
            separator: "|",
            omittingEmptySubsequences: false
        )
        let accountIsStableProviderID = accountParts.count == 3
            && ProviderKind(rawValue: String(accountParts[0])) != nil
            && accountParts[0] != Substring(ProviderKind.mediaShare.rawValue)
            && Self.isOpaqueSyncIdentifier(String(accountParts[1]))
            && Self.isOpaqueSyncIdentifier(String(accountParts[2]))
        return (accountIsOpaqueUUID || accountIsStableProviderID)
            && Self.isOpaqueSyncIdentifier(providerItemID)
    }

    static func isOpaqueSyncIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 256 else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0)
                || $0 == "-"
                || $0 == "_"
                || $0 == "."
        }
    }
}

public enum MediaAliasBindingSourceValidation: String, Codable, Hashable, Sendable {
    case observedBySource
    case assertedBySource
}

public struct MediaAliasProviderBindingHint: Codable, Hashable, Sendable, Comparable {
    public let binding: MediaAliasProviderBindingKey
    public var globalEvidence: [MediaIdentity]
    public var sourceValidation: MediaAliasBindingSourceValidation
    public var observedAt: Date?

    public init(
        binding: MediaAliasProviderBindingKey,
        globalEvidence: [MediaIdentity] = [],
        sourceValidation: MediaAliasBindingSourceValidation = .observedBySource,
        observedAt: Date? = nil
    ) {
        self.binding = binding
        self.globalEvidence = Self.canonicalGlobalEvidence(globalEvidence)
        self.sourceValidation = sourceValidation
        self.observedAt = observedAt
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.binding != rhs.binding { return lhs.binding < rhs.binding }
        if lhs.sourceValidation.rawValue != rhs.sourceValidation.rawValue {
            return lhs.sourceValidation.rawValue < rhs.sourceValidation.rawValue
        }
        if lhs.observedAt != rhs.observedAt {
            return (lhs.observedAt ?? .distantPast) < (rhs.observedAt ?? .distantPast)
        }
        return canonicalGlobalEvidenceKey(lhs.globalEvidence)
            < canonicalGlobalEvidenceKey(rhs.globalEvidence)
    }

    public func syncProjection() -> Self? {
        guard binding.isPrivacySafeForSync else { return nil }
        let safeGlobalEvidence = globalEvidence.filter { identity in
            guard case .external(let source, let value) = identity else { return false }
            let components = source.split(separator: ":", omittingEmptySubsequences: false)
            guard components.count == 2,
                  ProviderIDNamespace(rawValue: String(components[0])) != nil else {
                return false
            }
            let kind = String(components[1])
            guard kind == MediaItemKind.movie.rawValue
                    || kind == MediaItemKind.series.rawValue else {
                return false
            }
            return MediaAliasProviderBindingKey.isOpaqueSyncIdentifier(value)
        }
        return Self(
            binding: binding,
            globalEvidence: safeGlobalEvidence,
            sourceValidation: sourceValidation,
            observedAt: observedAt
        )
    }

    private static func canonicalGlobalEvidence(_ values: [MediaIdentity]) -> [MediaIdentity] {
        Array(Set(values.compactMap { identity -> MediaIdentity? in
            guard case .external(let source, let value) = identity else { return nil }
            let cleanSource = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let cleanValue = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !cleanSource.isEmpty, !cleanValue.isEmpty else { return nil }
            return .external(source: cleanSource, value: cleanValue)
        })).sorted {
            canonicalGlobalEvidenceKey([$0]) < canonicalGlobalEvidenceKey([$1])
        }
    }

    private static func canonicalGlobalEvidenceKey(_ values: [MediaIdentity]) -> String {
        values.compactMap { identity -> String? in
            guard case .external(let source, let value) = identity else { return nil }
            return source + "\u{0}" + value
        }.joined(separator: "\u{1}")
    }
}

public struct MediaAliasEvidence: Codable, Hashable, Sendable {
    public var kind: MediaItemKind
    public var strong: [MediaAliasStrongEvidence]
    public var weak: MediaAliasWeakEvidence?
    public var presentation: MediaAliasPresentation?
    public var bindingHints: [MediaAliasProviderBindingHint]
    public var locallyValidatedBindings: Set<MediaAliasProviderBindingKey>

    public init?(
        kind: MediaItemKind,
        strong: [MediaAliasStrongEvidence] = [],
        weak: MediaAliasWeakEvidence? = nil,
        presentation: MediaAliasPresentation? = nil,
        bindingHints: [MediaAliasProviderBindingHint] = [],
        locallyValidatedBindings: Set<MediaAliasProviderBindingKey> = []
    ) {
        guard kind == .movie || kind == .series else { return nil }
        self.kind = kind
        let canonicalStrong = Array(Set(strong.filter { $0.kind == kind })).sorted()
        guard Dictionary(grouping: canonicalStrong, by: \.namespace).values.allSatisfy({
            Set($0.map(\.value)).count == 1
        }) else {
            return nil
        }
        self.strong = canonicalStrong
        self.weak = weak?.kind == kind ? weak : nil
        self.presentation = presentation
        self.bindingHints = Self.canonicalHints(bindingHints)
        let hintKeys = Set(self.bindingHints.map(\.binding))
        self.locallyValidatedBindings = locallyValidatedBindings.intersection(hintKeys)
    }

    /// Evidence for `item`, optionally widened by the **canonical evidence of its
    /// cross-server component** so two copies of one title resolve to the same alias
    /// even when their payloads expose different id sets.
    public init?(
        item: MediaItem,
        canonicalEvidence: MediaIdentity? = nil,
        bindingHints: [MediaAliasProviderBindingHint] = [],
        locallyValidatedBindings: Set<MediaAliasProviderBindingKey> = []
    ) {
        guard item.kind == .movie || item.kind == .series else { return nil }
        // `plexGuid` is included deliberately: a Plex Discover / Watchlist row carries
        // *only* that id (the Discover fetch omits the external `Guid` array), so
        // without it every such row produced no strong evidence at all and fell to
        // weak title/year — the one case the ledger most needs to get right.
        var namespaces = MediaItemIdentity.strongExternalNamespaces.map(\.namespace)
        namespaces.append(.plexGuid)
        var strong = namespaces.compactMap { namespace -> MediaAliasStrongEvidence? in
            guard let value = item.providerID(namespace) else { return nil }
            return MediaAliasStrongEvidence(
                kind: item.kind,
                namespace: namespace,
                value: value
            )
        }
        if case .external(let source, let value)? = canonicalEvidence {
            let base = source.split(separator: ":", maxSplits: 1).first.map(String.init) ?? source
            if let namespace = Self.strongNamespacesByToken[base],
               let evidence = MediaAliasStrongEvidence(
                   kind: item.kind,
                   namespace: namespace,
                   value: value
               ),
               !strong.contains(where: { $0.namespace == namespace }) {
                strong.append(evidence)
            }
        }
        self.init(
            kind: item.kind,
            strong: strong,
            weak: MediaAliasWeakEvidence(
                kind: item.kind,
                title: item.title,
                year: item.productionYear
            ),
            presentation: MediaAliasPresentation(
                title: item.title,
                year: item.productionYear,
                artworkURL: item.posterURL?.absoluteString,
                backdropURL: (item.heroBackdropURL ?? item.backdropURL)?.absoluteString
            ),
            bindingHints: bindingHints,
            locallyValidatedBindings: locallyValidatedBindings
        )
    }

    static let strongNamespacesByToken: [String: ProviderIDNamespace] = {
        var result: [String: ProviderIDNamespace] = [:]
        for entry in MediaItemIdentity.strongExternalNamespaces {
            result[entry.canonical] = entry.namespace
        }
        result["plexguid"] = .plexGuid
        return result
    }()

    private static func canonicalHints(
        _ hints: [MediaAliasProviderBindingHint]
    ) -> [MediaAliasProviderBindingHint] {
        var byBinding: [MediaAliasProviderBindingKey: MediaAliasProviderBindingHint] = [:]
        for hint in hints.sorted() where byBinding[hint.binding] == nil {
            byBinding[hint.binding] = hint
        }
        return byBinding.values.sorted()
    }
}
