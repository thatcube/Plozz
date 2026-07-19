import Foundation

/// A stable, open identifier for the presentation role of an artwork candidate.
public struct ArtworkPlacement: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let homeHero = Self(rawValue: "homeHero")
    public static let detailBackdrop = Self(rawValue: "detailBackdrop")
    public static let poster = Self(rawValue: "poster")
    public static let seriesPoster = Self(rawValue: "seriesPoster")
    public static let logo = Self(rawValue: "logo")
    public static let episodeThumbnail = Self(rawValue: "episodeThumbnail")
    public static let seasonPoster = Self(rawValue: "seasonPoster")
    public static let seasonBanner = Self(rawValue: "seasonBanner")
    public static let banner = Self(rawValue: "banner")
}

public struct ArtworkDimensions: Codable, Hashable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) throws {
        guard width > 0, height > 0,
              width <= 16_384, height <= 16_384,
              Int64(width) * Int64(height) <= 64_000_000 else {
            throw ArtworkReferenceError.invalidDimensions
        }
        self.width = width
        self.height = height
    }

    public var aspectRatio: Double {
        Double(width) / Double(height)
    }

    private enum CodingKeys: String, CodingKey {
        case width
        case height
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            width: container.decode(Int.self, forKey: .width),
            height: container.decode(Int.self, forKey: .height)
        )
    }
}

/// Credential-free identity for one artwork file on a media-share account.
///
/// The account's credentials remain in the account store. The credential revision
/// only prevents a reference created under retired credentials from opening a new
/// transport session.
public struct NetworkArtworkReference: Codable, Hashable, Sendable {
    public let accountID: String
    public let credentialRevision: CredentialRevision
    public let catalogArtworkID: String
    public let representation: RemoteFileRepresentation
    public let sourceRevision: String
    public let contentType: String?
    public let dimensions: ArtworkDimensions?

    public init(
        accountID: String,
        credentialRevision: CredentialRevision,
        catalogArtworkID: String,
        representation: RemoteFileRepresentation,
        sourceRevision: String,
        contentType: String? = nil,
        dimensions: ArtworkDimensions? = nil
    ) throws {
        self.accountID = try ModelIdentifier.validated(accountID, field: "accountID")
        self.credentialRevision = credentialRevision
        let normalizedArtworkID = catalogArtworkID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedArtworkID.isEmpty else {
            throw ArtworkReferenceError.invalidCatalogArtworkID
        }
        self.catalogArtworkID = normalizedArtworkID
        let normalizedRevision = sourceRevision.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedRevision.isEmpty else {
            throw ArtworkReferenceError.invalidSourceRevision
        }
        self.representation = representation
        self.sourceRevision = normalizedRevision
        let normalizedType = contentType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.contentType = normalizedType?.isEmpty == false ? normalizedType : nil
        self.dimensions = dimensions
    }

    private enum CodingKeys: String, CodingKey {
        case accountID
        case credentialRevision
        case catalogArtworkID
        case relativePath
        case representation
        case sourceRevision
        case contentType
        case dimensions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let accountID = try container.decode(String.self, forKey: .accountID)
        guard let catalogArtworkID = try container.decodeIfPresent(
            String.self,
            forKey: .catalogArtworkID
        ) else {
            _ = try container.decodeIfPresent(String.self, forKey: .relativePath)
            throw ArtworkReferenceError.legacyPathOnlyReference
        }
        try self.init(
            accountID: accountID,
            credentialRevision: container.decode(
                CredentialRevision.self,
                forKey: .credentialRevision
            ),
            catalogArtworkID: catalogArtworkID,
            representation: container.decode(
                RemoteFileRepresentation.self,
                forKey: .representation
            ),
            sourceRevision: container.decode(String.self, forKey: .sourceRevision),
            contentType: container.decodeIfPresent(String.self, forKey: .contentType),
            dimensions: container.decodeIfPresent(ArtworkDimensions.self, forKey: .dimensions)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(accountID, forKey: .accountID)
        try container.encode(credentialRevision, forKey: .credentialRevision)
        try container.encode(catalogArtworkID, forKey: .catalogArtworkID)
        try container.encode(representation, forKey: .representation)
        try container.encode(sourceRevision, forKey: .sourceRevision)
        try container.encodeIfPresent(contentType, forKey: .contentType)
        try container.encodeIfPresent(dimensions, forKey: .dimensions)
    }
}

public enum ArtworkReference: Codable, Hashable, Sendable {
    case remote(URL)
    case networkFile(NetworkArtworkReference)

    private enum CodingKeys: String, CodingKey {
        case kind
        case remoteURL
        case networkFile
    }

    private enum Kind: String, Codable {
        case remote
        case networkFile
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .remote:
            self = .remote(try container.decode(URL.self, forKey: .remoteURL))
        case .networkFile:
            self = .networkFile(
                try container.decode(NetworkArtworkReference.self, forKey: .networkFile)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .remote(let url):
            try container.encode(Kind.remote, forKey: .kind)
            try container.encode(url, forKey: .remoteURL)
        case .networkFile(let reference):
            try container.encode(Kind.networkFile, forKey: .kind)
            try container.encode(reference, forKey: .networkFile)
        }
    }
}

public extension ArtworkReference {
    /// Stable identity suitable for UI task/cache keys. Network references deliberately
    /// exclude their relative path so UI diagnostics and identifiers never expose it.
    var privacySafeIdentity: String {
        switch self {
        case .remote(let url):
            return "remote|\(url.absoluteString)"
        case .networkFile(let reference):
            return "network|\(reference.accountID)|\(reference.credentialRevision.rawValue.uuidString)|\(reference.catalogArtworkID)|\(reference.sourceRevision)"
        }
    }
}

/// Ordered candidates for one placement. The first entry is the deterministic
/// winner; later entries are local fallbacks tried before legacy remote artwork.
public struct ArtworkSelection: Codable, Hashable, Sendable {
    public let placement: ArtworkPlacement
    public let references: [ArtworkReference]

    public init(placement: ArtworkPlacement, references: [ArtworkReference]) {
        self.placement = placement
        var seen = Set<ArtworkReference>()
        self.references = references.filter { seen.insert($0).inserted }
    }

    private enum CodingKeys: String, CodingKey {
        case placement
        case references
    }

    private struct TolerantReference: Decodable {
        let value: ArtworkReference?

        init(from decoder: Decoder) {
            value = try? ArtworkReference(from: decoder)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            placement: try container.decode(ArtworkPlacement.self, forKey: .placement),
            references: try container.decode([TolerantReference].self, forKey: .references)
                .compactMap(\.value)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(placement, forKey: .placement)
        try container.encode(references, forKey: .references)
    }
}

public enum ArtworkReferenceError: Error, Equatable {
    case invalidDimensions
    case invalidCatalogArtworkID
    case legacyPathOnlyReference
    case invalidSourceRevision
}
