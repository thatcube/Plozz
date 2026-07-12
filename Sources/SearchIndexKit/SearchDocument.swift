import CryptoKit
import Foundation
import CoreModels

public struct SearchIndexDocument: Codable, Hashable, Sendable {
    public let sourceKey: String
    public let accountID: String
    public let providerUserKey: String
    public let libraryID: String?
    public let item: MediaItem
    public let normalizedTitle: String
    public let normalizedParentTitle: String?
    public let metadataText: String
    public let semanticTexts: [String]
    public let contentHash: String

    public init(
        sourceKey: String,
        accountID: String,
        providerUserKey: String,
        libraryID: String?,
        item: MediaItem,
        normalizedTitle: String,
        normalizedParentTitle: String?,
        metadataText: String,
        semanticTexts: [String],
        contentHash: String
    ) {
        self.sourceKey = sourceKey
        self.accountID = accountID
        self.providerUserKey = providerUserKey
        self.libraryID = libraryID
        self.item = item
        self.normalizedTitle = normalizedTitle
        self.normalizedParentTitle = normalizedParentTitle
        self.metadataText = metadataText
        self.semanticTexts = semanticTexts
        self.contentHash = contentHash
    }
}

public struct SearchDocumentBuilder: Sendable {
    public init() {}

    public func document(
        for item: MediaItem,
        accountID: String,
        providerUserKey: String
    ) -> SearchIndexDocument {
        let taggedItem = item.taggingSource(accountID)
        let sourceKey = MediaSourceRef(accountID: accountID, itemID: item.id).id
        let metadataParts = [
            item.parentTitle,
            item.title,
            item.originalTitle,
            episodeLabel(for: item),
            item.productionYear.map(String.init),
            joined(item.genres),
            joined(item.tags),
            joined(item.taglines),
            joined(item.studios),
            joined(item.people.map(personText))
        ].compactMap { value -> String? in
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let metadataText = metadataParts.joined(separator: ". ")
        let overview = item.overview?.trimmingCharacters(in: .whitespacesAndNewlines)
        let semanticTexts: [String] = [Optional(metadataText), overview]
            .compactMap { text -> String? in
                guard let text, !text.isEmpty else { return nil }
                return text
            }
        let canonical = [
            item.kind.rawValue,
            item.libraryID ?? "",
            metadataText,
            overview ?? ""
        ].joined(separator: "\u{1F}")

        return SearchIndexDocument(
            sourceKey: sourceKey,
            accountID: accountID,
            providerUserKey: providerUserKey,
            libraryID: item.libraryID,
            item: taggedItem,
            normalizedTitle: Self.normalized(item.title),
            normalizedParentTitle: item.parentTitle.map(Self.normalized),
            metadataText: metadataText,
            semanticTexts: semanticTexts,
            contentHash: Self.sha256(canonical)
        )
    }

    public static func normalized(_ value: String) -> String {
        value
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private func episodeLabel(for item: MediaItem) -> String? {
        guard item.kind == .episode else { return nil }
        switch (item.seasonNumber, item.episodeNumber) {
        case let (.some(season), .some(episode)):
            return "Season \(season) Episode \(episode)"
        case let (.some(season), nil):
            return "Season \(season)"
        case let (nil, .some(episode)):
            return "Episode \(episode)"
        case (nil, nil):
            return "Episode"
        }
    }

    private func joined(_ values: [String]) -> String? {
        values.isEmpty ? nil : values.joined(separator: ", ")
    }

    private func personText(_ person: MediaPerson) -> String {
        [person.name, person.role, person.kind]
            .compactMap { $0 }
            .joined(separator: " ")
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
