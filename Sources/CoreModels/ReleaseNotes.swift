import Foundation
import Observation

public enum ReleaseNotesCategory: String, Codable, CaseIterable, Sendable {
    case new = "New"
    case updated = "Updated"
    case fixed = "Fixed"
}

public struct ReleaseNotesSection: Codable, Equatable, Identifiable, Sendable {
    public let category: ReleaseNotesCategory
    public let items: [String]

    public var id: ReleaseNotesCategory { category }

    public init(category: ReleaseNotesCategory, items: [String]) {
        self.category = category
        self.items = items
    }
}

public struct ReleaseNotesRelease: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let version: String
    public let build: Int
    public let releasedAt: String
    public let sections: [ReleaseNotesSection]

    public init(
        id: String,
        version: String,
        build: Int,
        releasedAt: String,
        sections: [ReleaseNotesSection]
    ) {
        self.id = id
        self.version = version
        self.build = build
        self.releasedAt = releasedAt
        self.sections = sections
    }
}

public struct ReleaseNotesVersionGroup: Equatable, Identifiable, Sendable {
    public let version: String
    public let sections: [ReleaseNotesSection]

    public var id: String { version }
}

public enum ReleaseNotesCatalogError: LocalizedError, Equatable {
    case missingResource
    case unsupportedSchemaVersion(Int)
    case releasesNotNewestFirst
    case duplicateReleaseID(String)
    case duplicateBuild(Int)
    case invalidReleaseID(String, build: Int)
    case invalidVersion(String)
    case invalidReleaseDate(String)
    case missingSections(String)
    case invalidSectionOrder(String)
    case emptySection(String, ReleaseNotesCategory)
    case emptyItem(String, ReleaseNotesCategory)
    case duplicateItem(String, ReleaseNotesCategory)
    case versionsNotNewestFirst

    public var errorDescription: String? {
        switch self {
        case .missingResource:
            return "ReleaseNotes.json is missing from the app bundle."
        case let .unsupportedSchemaVersion(version):
            return "ReleaseNotes.json uses unsupported schema version \(version)."
        case .releasesNotNewestFirst:
            return "ReleaseNotes.json releases must be ordered by descending build number."
        case let .duplicateReleaseID(id):
            return "ReleaseNotes.json contains duplicate release id \(id)."
        case let .duplicateBuild(build):
            return "ReleaseNotes.json contains duplicate build \(build)."
        case let .invalidReleaseID(id, build):
            return "Release id \(id) does not match build \(build)."
        case let .invalidVersion(version):
            return "ReleaseNotes.json contains invalid version \(version)."
        case let .invalidReleaseDate(date):
            return "ReleaseNotes.json contains invalid release date \(date)."
        case let .missingSections(id):
            return "Release \(id) has no release-note sections."
        case let .invalidSectionOrder(id):
            return "Release \(id) sections must follow New, Updated, Fixed order without duplicates."
        case let .emptySection(id, category):
            return "Release \(id) has an empty \(category.rawValue) section."
        case let .emptyItem(id, category):
            return "Release \(id) has an empty item in \(category.rawValue)."
        case let .duplicateItem(id, category):
            return "Release \(id) repeats an item in \(category.rawValue)."
        case .versionsNotNewestFirst:
            return "ReleaseNotes.json versions must be ordered newest first."
        }
    }
}

public struct ReleaseNotesCatalog: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let releases: [ReleaseNotesRelease]

    public init(schemaVersion: Int = 1, releases: [ReleaseNotesRelease]) throws {
        self.schemaVersion = schemaVersion
        self.releases = releases
        try validate()
    }

    public init(data: Data) throws {
        self = try JSONDecoder().decode(Self.self, from: data)
        try validate()
    }

    public static func load(from bundle: Bundle = .main) throws -> Self {
        guard let url = bundle.url(forResource: "ReleaseNotes", withExtension: "json") else {
            throw ReleaseNotesCatalogError.missingResource
        }

        return try Self(data: Data(contentsOf: url))
    }

    public static let empty = Self(schemaVersion: 1, releases: [], validated: ())

    public func release(id: String) -> ReleaseNotesRelease? {
        releases.first { $0.id == id }
    }

    public func releases(after lastSeenID: String, through currentID: String) -> [ReleaseNotesRelease] {
        guard
            let lastSeen = release(id: lastSeenID),
            let current = release(id: currentID),
            lastSeen.build < current.build
        else {
            return []
        }
        return releases.filter { $0.build > lastSeen.build && $0.build <= current.build }
    }

    public func versionGroups(for releases: [ReleaseNotesRelease]? = nil) -> [ReleaseNotesVersionGroup] {
        let source = releases ?? self.releases
        var grouped: [(version: String, items: [ReleaseNotesCategory: [String]])] = []

        for release in source {
            let index: Int
            if let existing = grouped.firstIndex(where: { $0.version == release.version }) {
                index = existing
            } else {
                grouped.append((release.version, [:]))
                index = grouped.endIndex - 1
            }

            for section in release.sections {
                var items = grouped[index].items[section.category, default: []]
                for item in section.items where !items.contains(item) {
                    items.append(item)
                }
                grouped[index].items[section.category] = items
            }
        }

        return grouped.map { group in
            ReleaseNotesVersionGroup(
                version: group.version,
                sections: ReleaseNotesCategory.allCases.compactMap { category in
                    guard let items = group.items[category], !items.isEmpty else { return nil }
                    return ReleaseNotesSection(category: category, items: items)
                }
            )
        }
    }

    private init(schemaVersion: Int, releases: [ReleaseNotesRelease], validated: Void) {
        self.schemaVersion = schemaVersion
        self.releases = releases
    }

    private func validate() throws {
        guard schemaVersion == 1 else {
            throw ReleaseNotesCatalogError.unsupportedSchemaVersion(schemaVersion)
        }
        var ids = Set<String>()
        var builds = Set<Int>()
        for release in releases {
            guard ids.insert(release.id).inserted else {
                throw ReleaseNotesCatalogError.duplicateReleaseID(release.id)
            }
            guard builds.insert(release.build).inserted else {
                throw ReleaseNotesCatalogError.duplicateBuild(release.build)
            }
            let expectedID = String(format: "release/%03d", release.build)
            guard release.id == expectedID else {
                throw ReleaseNotesCatalogError.invalidReleaseID(release.id, build: release.build)
            }
            let versionParts = release.version.split(separator: ".", omittingEmptySubsequences: false)
            guard
                versionParts.count == 3,
                versionParts.allSatisfy({
                    !$0.isEmpty && $0.allSatisfy(\.isNumber)
                })
            else {
                throw ReleaseNotesCatalogError.invalidVersion(release.version)
            }
            let dateParts = release.releasedAt.split(separator: "-", omittingEmptySubsequences: false)
            guard
                dateParts.count == 3,
                dateParts[0].count == 4,
                dateParts[1].count == 2,
                dateParts[2].count == 2,
                dateParts.allSatisfy({
                    !$0.isEmpty && $0.allSatisfy(\.isNumber)
                })
            else {
                throw ReleaseNotesCatalogError.invalidReleaseDate(release.releasedAt)
            }
            guard !release.sections.isEmpty else {
                throw ReleaseNotesCatalogError.missingSections(release.id)
            }

            let categories = release.sections.map(\.category)
            let expectedCategories = ReleaseNotesCategory.allCases.filter(categories.contains)
            guard categories == expectedCategories else {
                throw ReleaseNotesCatalogError.invalidSectionOrder(release.id)
            }

            for section in release.sections {
                guard !section.items.isEmpty else {
                    throw ReleaseNotesCatalogError.emptySection(release.id, section.category)
                }
                guard section.items.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                    throw ReleaseNotesCatalogError.emptyItem(release.id, section.category)
                }
                guard Set(section.items).count == section.items.count else {
                    throw ReleaseNotesCatalogError.duplicateItem(release.id, section.category)
                }
            }
        }

        guard zip(releases, releases.dropFirst()).allSatisfy({ pair in
            pair.0.build > pair.1.build
        }) else {
            throw ReleaseNotesCatalogError.releasesNotNewestFirst
        }
        guard zip(releases, releases.dropFirst()).allSatisfy({ pair in
            let newer = pair.0.version.split(separator: ".").compactMap { Int($0) }
            let older = pair.1.version.split(separator: ".").compactMap { Int($0) }
            return !newer.lexicographicallyPrecedes(older)
        }) else {
            throw ReleaseNotesCatalogError.versionsNotNewestFirst
        }
    }
}

public protocol ReleaseNotesStoring: Sendable {
    func loadShowsOnStartup() -> Bool
    func saveShowsOnStartup(_ showsOnStartup: Bool)
    func loadLastSeenReleaseID() -> String?
    func saveLastSeenReleaseID(_ releaseID: String)
}

public final class ReleaseNotesStore: ReleaseNotesStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let showsOnStartupKey = "com.plozz.releaseNotes.showsOnStartup"
    private let lastSeenReleaseIDKey = "com.plozz.releaseNotes.lastSeenReleaseID"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func loadShowsOnStartup() -> Bool {
        guard defaults.object(forKey: showsOnStartupKey) != nil else { return true }
        return defaults.bool(forKey: showsOnStartupKey)
    }

    public func saveShowsOnStartup(_ showsOnStartup: Bool) {
        defaults.set(showsOnStartup, forKey: showsOnStartupKey)
    }

    public func loadLastSeenReleaseID() -> String? {
        defaults.string(forKey: lastSeenReleaseIDKey)
    }

    public func saveLastSeenReleaseID(_ releaseID: String) {
        defaults.set(releaseID, forKey: lastSeenReleaseIDKey)
    }
}

@MainActor
@Observable
public final class ReleaseNotesModel {
    public static let shared: ReleaseNotesModel = {
        do {
            return try ReleaseNotesModel(
                catalog: ReleaseNotesCatalog.load(),
                currentReleaseID: Bundle.main.object(
                    forInfoDictionaryKey: "PlozzReleaseID"
                ) as? String
            )
        } catch {
            assertionFailure("Invalid bundled release notes: \(error.localizedDescription)")
            return ReleaseNotesModel(
                catalog: .empty,
                currentReleaseID: nil,
                isAvailable: false
            )
        }
    }()

    public let catalog: ReleaseNotesCatalog
    public let allVersionGroups: [ReleaseNotesVersionGroup]
    public let isAvailable: Bool
    public private(set) var showsOnStartup: Bool
    public private(set) var pendingReleases: [ReleaseNotesRelease] = []
    public private(set) var pendingVersionGroups: [ReleaseNotesVersionGroup] = []

    public var hasPendingStartupNotes: Bool {
        !pendingReleases.isEmpty
    }

    private let currentReleaseID: String?
    private let store: ReleaseNotesStoring
    private var didPrepareForStartup = false

    public init(
        catalog: ReleaseNotesCatalog,
        currentReleaseID: String?,
        store: ReleaseNotesStoring = ReleaseNotesStore(),
        isAvailable: Bool = true
    ) {
        self.catalog = catalog
        self.allVersionGroups = catalog.versionGroups()
        self.isAvailable = isAvailable
        self.currentReleaseID = currentReleaseID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.store = store
        self.showsOnStartup = store.loadShowsOnStartup()
    }

    public func prepareForStartup() {
        guard !didPrepareForStartup else { return }
        didPrepareForStartup = true
        guard let current = currentRelease else { return }

        guard let lastSeenID = store.loadLastSeenReleaseID() else {
            store.saveLastSeenReleaseID(current.id)
            return
        }
        guard catalog.release(id: lastSeenID) != nil else {
            store.saveLastSeenReleaseID(current.id)
            return
        }

        guard showsOnStartup else {
            advanceLastSeen(to: current)
            return
        }

        let unseen = catalog.releases(after: lastSeenID, through: current.id)
        guard !unseen.isEmpty else { return }
        pendingReleases = unseen
        pendingVersionGroups = catalog.versionGroups(for: unseen)
    }

    public func dismissStartupNotes() {
        if let current = currentRelease {
            advanceLastSeen(to: current)
        }
        pendingReleases = []
        pendingVersionGroups = []
    }

    public func setShowsOnStartup(_ showsOnStartup: Bool) {
        guard self.showsOnStartup != showsOnStartup else { return }
        self.showsOnStartup = showsOnStartup
        store.saveShowsOnStartup(showsOnStartup)

        if !showsOnStartup, let current = currentRelease {
            advanceLastSeen(to: current)
            pendingReleases = []
            pendingVersionGroups = []
        }
    }

    private var currentRelease: ReleaseNotesRelease? {
        guard let currentReleaseID, !currentReleaseID.isEmpty else { return nil }
        return catalog.release(id: currentReleaseID)
    }

    private func advanceLastSeen(to release: ReleaseNotesRelease) {
        if
            let savedID = store.loadLastSeenReleaseID(),
            let saved = catalog.release(id: savedID),
            saved.build >= release.build
        {
            return
        }
        store.saveLastSeenReleaseID(release.id)
    }
}
