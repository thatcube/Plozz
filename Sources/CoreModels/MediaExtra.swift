import Foundation

public enum MediaExtraKind: String, Codable, Hashable, Sendable {
    case trailer
    case featurette
    case behindTheScenes
    case deletedScene
    case interview
    case scene
    case sample
    case sceneOrSample
    case musicPerformance
    case short
    case other
    case unknown

    public init(rawProviderValue value: String?) {
        let normalized = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .filter(\.isLetter)

        switch normalized {
        case "trailer", "trailers":
            self = .trailer
        case "featurette", "featurettes":
            self = .featurette
        case "behindthescenes", "behindscene":
            self = .behindTheScenes
        case "deleted", "deletedscene", "deletedscenes":
            self = .deletedScene
        case "interview", "interviews":
            self = .interview
        case "scene", "scenes", "clip", "clips":
            self = .scene
        case "sample", "samples":
            self = .sample
        case "sceneorsample":
            self = .sceneOrSample
        case "musicvideo", "livemusicvideo", "lyricmusicvideo", "concert",
             "performance", "performances":
            self = .musicPerformance
        case "short", "shorts":
            self = .short
        case "extra", "extras", "other":
            self = .other
        case nil, "":
            self = .unknown
        default:
            self = .unknown
        }
    }

    public var displayName: LocalizedStringResource {
        switch self {
        case .trailer: "Trailer"
        case .featurette: "Featurette"
        case .behindTheScenes: "Behind the Scenes"
        case .deletedScene: "Deleted Scene"
        case .interview: "Interview"
        case .scene: "Scene"
        case .sample: "Sample"
        case .sceneOrSample: "Scene / Sample"
        case .musicPerformance: "Music & Performance"
        case .short: "Short"
        case .other, .unknown: "Extra"
        }
    }

    public var sortOrder: Int {
        switch self {
        case .trailer: 0
        case .featurette: 1
        case .behindTheScenes: 2
        case .deletedScene: 3
        case .interview: 4
        case .scene, .sample, .sceneOrSample: 5
        case .musicPerformance: 6
        case .short: 7
        case .other, .unknown: 8
        }
    }
}

public enum MediaExtraOwnerKind: String, Codable, Hashable, Sendable {
    case movie
    case series
    case season
    case episode
    case collection
    case other

    public init(mediaKind: MediaItemKind) {
        switch mediaKind {
        case .movie: self = .movie
        case .series: self = .series
        case .season: self = .season
        case .episode: self = .episode
        case .collection: self = .collection
        default: self = .other
        }
    }
}

public struct MediaExtraOwner: Codable, Hashable, Sendable {
    public let id: String
    public let kind: MediaExtraOwnerKind
    public let title: String?

    public init(id: String, kind: MediaExtraOwnerKind, title: String? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
    }

    public init(item: MediaItem) {
        self.init(
            id: item.id,
            kind: MediaExtraOwnerKind(mediaKind: item.kind),
            title: item.title
        )
    }
}

public struct MediaExtra: Codable, Hashable, Identifiable, Sendable {
    public var item: MediaItem
    public let kind: MediaExtraKind
    public let rawProviderType: String?
    public let owner: MediaExtraOwner?
    public let supportsResume: Bool
    public let isPrimary: Bool

    public var id: String { item.stablePresentationID }

    public init(
        item: MediaItem,
        kind: MediaExtraKind,
        rawProviderType: String? = nil,
        owner: MediaExtraOwner? = nil,
        supportsResume: Bool = true,
        isPrimary: Bool = false
    ) {
        self.item = item
        self.kind = kind
        self.rawProviderType = rawProviderType
        self.owner = owner
        self.supportsResume = supportsResume
        self.isPrimary = isPrimary
    }

    public func attaching(to owner: MediaItem) -> MediaExtra {
        MediaExtra(
            item: item,
            kind: kind,
            rawProviderType: rawProviderType,
            owner: MediaExtraOwner(item: owner),
            supportsResume: supportsResume,
            isPrimary: isPrimary
        )
    }

    public func taggingSource(_ accountID: String) -> MediaExtra {
        var copy = self
        copy.item = item.taggingSource(accountID)
        return copy
    }

    public var playbackItem: MediaItem {
        guard !supportsResume else { return item }
        var copy = item
        copy.resumePosition = nil
        copy.playedPercentage = copy.isPlayed ? 1 : nil
        return copy
    }

    public static func ordered(_ extras: [MediaExtra]) -> [MediaExtra] {
        var seen = Set<String>()
        return extras.enumerated()
            .filter { seen.insert($0.element.id).inserted }
            .sorted {
                let left = $0.element.kind.sortOrder
                let right = $1.element.kind.sortOrder
                return left == right ? $0.offset < $1.offset : left < right
            }
            .map(\.element)
    }
}
