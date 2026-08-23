import Foundation

public enum MediaAliasConflictKind: String, Codable, Hashable, Sendable {
    case strongEvidence
    case duplicateSplit
}

public struct MediaAliasConflict: Codable, Hashable, Sendable, Comparable {
    public let kind: MediaAliasConflictKind
    public let namespace: ProviderIDNamespace?
    public let existingValue: String
    public let rejectedValue: String
    public let recordedAt: Date

    public init(
        kind: MediaAliasConflictKind,
        namespace: ProviderIDNamespace? = nil,
        existingValue: String,
        rejectedValue: String,
        recordedAt: Date
    ) {
        self.kind = kind
        self.namespace = namespace
        self.existingValue = existingValue
        self.rejectedValue = rejectedValue
        self.recordedAt = recordedAt
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.recordedAt != rhs.recordedAt { return lhs.recordedAt < rhs.recordedAt }
        if lhs.kind.rawValue != rhs.kind.rawValue { return lhs.kind.rawValue < rhs.kind.rawValue }
        if lhs.namespace?.rawValue != rhs.namespace?.rawValue {
            return (lhs.namespace?.rawValue ?? "") < (rhs.namespace?.rawValue ?? "")
        }
        if lhs.existingValue != rhs.existingValue { return lhs.existingValue < rhs.existingValue }
        return lhs.rejectedValue < rhs.rejectedValue
    }
}

/// Durable identity only. Consumer state such as watchlist membership, ratings,
/// notes, or recommendations belongs in separate records keyed by ``id``.
public struct MediaAliasRecord: Codable, Hashable, Identifiable, Sendable {
    public let id: MediaAliasID
    public let kind: MediaItemKind
    public var createdAt: Date
    public var updatedAt: Date
    public var strongEvidence: [MediaAliasStrongEvidence]
    public var weakEvidence: [MediaAliasWeakEvidence]
    public var presentation: MediaAliasPresentation?
    public var bindingHints: [MediaAliasProviderBindingHint]
    public var locallyValidatedBindings: Set<MediaAliasProviderBindingKey>
    /// See ``MediaAliasLocalSourceKey``. A lookup handle, never a write target:
    /// it is what makes a record minted from otherwise unidentifiable evidence
    /// findable again by the surface that minted it.
    public var localSources: Set<MediaAliasLocalSourceKey>
    public var redirectTarget: MediaAliasID?
    public var conflicts: [MediaAliasConflict]

    public init?(
        id: MediaAliasID = MediaAliasID(),
        kind: MediaItemKind,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        strongEvidence: [MediaAliasStrongEvidence] = [],
        weakEvidence: [MediaAliasWeakEvidence] = [],
        presentation: MediaAliasPresentation? = nil,
        bindingHints: [MediaAliasProviderBindingHint] = [],
        locallyValidatedBindings: Set<MediaAliasProviderBindingKey> = [],
        localSources: Set<MediaAliasLocalSourceKey> = [],
        redirectTarget: MediaAliasID? = nil,
        conflicts: [MediaAliasConflict] = []
    ) {
        guard kind == .movie || kind == .series, redirectTarget != id else { return nil }
        self.id = id
        self.kind = kind
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.strongEvidence = strongEvidence
        self.weakEvidence = weakEvidence
        self.presentation = presentation
        self.bindingHints = bindingHints
        self.locallyValidatedBindings = locallyValidatedBindings
        self.localSources = localSources
        self.redirectTarget = redirectTarget
        self.conflicts = conflicts
        canonicalize()
        guard !Self.hasInternalStrongConflict(self.strongEvidence) else { return nil }
    }

    public mutating func canonicalize() {
        strongEvidence = Array(Set(strongEvidence.compactMap {
            evidence -> MediaAliasStrongEvidence? in
            guard evidence.kind == kind else { return nil }
            return MediaAliasStrongEvidence(
                kind: evidence.kind,
                namespace: evidence.namespace,
                value: evidence.value
            )
        })).sorted()
        weakEvidence = Array(Set(weakEvidence.compactMap {
            evidence -> MediaAliasWeakEvidence? in
            guard evidence.kind == kind else { return nil }
            return MediaAliasWeakEvidence(
                kind: evidence.kind,
                normalizedTitle: evidence.normalizedTitle,
                year: evidence.year
            )
        })).sorted()
        var hints: [MediaAliasProviderBindingKey: MediaAliasProviderBindingHint] = [:]
        for hint in bindingHints {
            guard let binding = MediaAliasProviderBindingKey(
                providerKind: hint.binding.providerKind,
                accountDescriptorID: hint.binding.accountDescriptorID,
                providerItemID: hint.binding.providerItemID
            ) else {
                continue
            }
            let clean = MediaAliasProviderBindingHint(
                binding: binding,
                globalEvidence: hint.globalEvidence,
                sourceValidation: hint.sourceValidation,
                observedAt: hint.observedAt
            )
            if let current = hints[binding] {
                hints[binding] = min(current, clean)
            } else {
                hints[binding] = clean
            }
        }
        bindingHints = hints.values.sorted()
        locallyValidatedBindings.formIntersection(Set(bindingHints.map(\.binding)))
        conflicts = Array(Set(conflicts)).sorted()
        presentation = presentation?.sanitizedForSync()
    }

    public func canonicalized() -> Self {
        var copy = self
        copy.canonicalize()
        return copy
    }

    public func canonicalData() -> Data? {
        CanonicalJSON.encode(canonicalized())
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, createdAt, updatedAt, strongEvidence, weakEvidence, presentation
        case bindingHints, locallyValidatedBindings, localSources, redirectTarget, conflicts
    }

    public func encode(to encoder: Encoder) throws {
        let value = canonicalized()
        guard !Self.hasInternalStrongConflict(value.strongEvidence) else {
            throw EncodingError.invalidValue(
                value.strongEvidence,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: "A media alias cannot hold conflicting strong IDs in one namespace."
                )
            )
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value.id, forKey: .id)
        try container.encode(value.kind, forKey: .kind)
        try container.encode(value.createdAt, forKey: .createdAt)
        try container.encode(value.updatedAt, forKey: .updatedAt)
        try container.encode(value.strongEvidence, forKey: .strongEvidence)
        try container.encode(value.weakEvidence, forKey: .weakEvidence)
        try container.encodeIfPresent(value.presentation, forKey: .presentation)
        try container.encode(value.bindingHints, forKey: .bindingHints)
        try container.encode(
            value.locallyValidatedBindings.sorted(),
            forKey: .locallyValidatedBindings
        )
        // Only when there is something to say. A record with no local sources —
        // every record that predates this field, and every one built purely from
        // catalogue ids — must encode byte-for-byte as it did before, because the
        // canonical encoding is what sync compares and what the ledger's payload
        // budget is measured against.
        if !value.localSources.isEmpty {
            try container.encode(
                value.localSources.sorted(),
                forKey: .localSources
            )
        }
        try container.encodeIfPresent(value.redirectTarget, forKey: .redirectTarget)
        try container.encode(value.conflicts, forKey: .conflicts)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(MediaAliasID.self, forKey: .id)
        kind = try container.decode(MediaItemKind.self, forKey: .kind)
        guard kind == .movie || kind == .series else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Media aliases support movies and series only."
            )
        }
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        strongEvidence = try container.decodeIfPresent(
            [MediaAliasStrongEvidence].self,
            forKey: .strongEvidence
        ) ?? []
        weakEvidence = try container.decodeIfPresent(
            [MediaAliasWeakEvidence].self,
            forKey: .weakEvidence
        ) ?? []
        presentation = try container.decodeIfPresent(
            MediaAliasPresentation.self,
            forKey: .presentation
        )
        bindingHints = try container.decodeIfPresent(
            [MediaAliasProviderBindingHint].self,
            forKey: .bindingHints
        ) ?? []
        locallyValidatedBindings = Set(try container.decodeIfPresent(
            [MediaAliasProviderBindingKey].self,
            forKey: .locallyValidatedBindings
        ) ?? [])
        localSources = Set(try container.decodeIfPresent(
            [MediaAliasLocalSourceKey].self,
            forKey: .localSources
        ) ?? [])
        redirectTarget = try container.decodeIfPresent(
            MediaAliasID.self,
            forKey: .redirectTarget
        )
        conflicts = try container.decodeIfPresent(
            [MediaAliasConflict].self,
            forKey: .conflicts
        ) ?? []
        guard redirectTarget != id else {
            throw DecodingError.dataCorruptedError(
                forKey: .redirectTarget,
                in: container,
                debugDescription: "Media alias cannot redirect to itself."
            )
        }
        canonicalize()
        guard !Self.hasInternalStrongConflict(strongEvidence) else {
            throw DecodingError.dataCorruptedError(
                forKey: .strongEvidence,
                in: container,
                debugDescription: "A media alias cannot hold conflicting strong IDs in one namespace."
            )
        }
    }

    private static func hasInternalStrongConflict(
        _ evidence: [MediaAliasStrongEvidence]
    ) -> Bool {
        Dictionary(grouping: evidence, by: \.namespace).values.contains {
            Set($0.map(\.value)).count > 1
        }
    }
}
