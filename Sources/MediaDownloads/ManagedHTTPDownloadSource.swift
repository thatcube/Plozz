import CoreModels
import Foundation

/// Secret-free reopen information for a managed-provider background download.
///
/// Credentials and resolved URLs are deliberately excluded. The iOS app resolves
/// a fresh authenticated URL from the active account each time work starts or
/// resumes.
public struct ManagedHTTPDownloadSource: Codable, Sendable, Hashable {
    public let provider: ProviderKind
    public let accountID: String
    public let itemID: String
    public let mediaSourceID: String?
    public let quality: DownloadQuality
    public let includesAllAudioTracks: Bool
    public let includesTextSubtitleTracks: Bool

    public init(
        provider: ProviderKind,
        accountID: String,
        itemID: String,
        mediaSourceID: String? = nil,
        quality: DownloadQuality = .original,
        includesAllAudioTracks: Bool = false,
        includesTextSubtitleTracks: Bool = true
    ) {
        self.provider = provider
        self.accountID = accountID
        self.itemID = itemID
        self.mediaSourceID = mediaSourceID
        self.quality = quality
        self.includesAllAudioTracks = includesAllAudioTracks
        self.includesTextSubtitleTracks = includesTextSubtitleTracks
    }

    private enum CodingKeys: String, CodingKey {
        case provider
        case accountID
        case itemID
        case mediaSourceID
        case quality
        case includesAllAudioTracks
        case includesTextSubtitleTracks
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decode(ProviderKind.self, forKey: .provider)
        accountID = try container.decode(String.self, forKey: .accountID)
        itemID = try container.decode(String.self, forKey: .itemID)
        mediaSourceID = try container.decodeIfPresent(String.self, forKey: .mediaSourceID)
        quality = try container.decodeIfPresent(DownloadQuality.self, forKey: .quality)
            ?? .original
        includesAllAudioTracks = try container.decodeIfPresent(
            Bool.self,
            forKey: .includesAllAudioTracks
        ) ?? false
        includesTextSubtitleTracks = try container.decodeIfPresent(
            Bool.self,
            forKey: .includesTextSubtitleTracks
        ) ?? true
    }
}
