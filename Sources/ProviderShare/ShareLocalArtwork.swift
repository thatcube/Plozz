import Foundation
import CoreModels
import MediaTransportCore

enum ShareArtworkRole: String, Sendable, Hashable {
    case poster
    case backdrop
    case landscape
    case logo
    case banner
    case episodeThumbnail
    case exactStem
}

struct ShareArtworkNameFacts: Sendable, Equatable, Hashable {
    var stem: String
    var role: ShareArtworkRole?
    var explicitMediaStem: String?
    var numberedAlternative: Int?
    var language: String?
    var season: Int?
    var isSpecialsSeason: Bool
}

/// Pure, listing-only parser for the common Kodi/Jellyfin/Emby/TMM artwork
/// conventions. It deliberately does not infer a media owner; that needs the
/// persisted catalog topology and is handled by the association policy.
enum ShareArtworkNameParser {
    static let supportedExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "tbn"]

    static func parse(_ basename: String) -> ShareArtworkNameFacts? {
        let ns = basename as NSString
        let ext = ns.pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else { return nil }
        let rawStem = ns.deletingPathExtension
        guard !rawStem.isEmpty else { return nil }
        var stem = rawStem.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stem.isEmpty else { return nil }

        var language: String?
        if let range = stem.range(of: #"(?:[._ -])(en|eng|fr|fra|fre|de|ger|es|spa|it|ita|pt|por|ja|jpn|ko|kor|zh|zho|chi)$"#,
                                  options: .regularExpression) {
            language = String(stem[range]).trimmingCharacters(in: CharacterSet(charactersIn: "._ -"))
            stem.removeSubrange(range)
        }

        let season = seasonFacts(stem)
        var numbered: Int?
        var name = stem
        if let match = name.range(of: #"(?:-|_)?([0-9]+)$"#, options: .regularExpression),
           let value = Int(name[match].trimmingCharacters(in: CharacterSet(charactersIn: "-_"))) {
            let before = String(name[..<match.lowerBound])
            let normalizedBefore = before.trimmingCharacters(in: CharacterSet(charactersIn: "-_ "))
            let isNamedAlternative = role(for: normalizedBefore) != nil
                || ["thumbnail", "thumb", "clearlogo", "backdrop", "fanart", "poster", "logo", "banner"]
                    .contains { normalizedBefore.hasSuffix("-\($0)") }
            if isNamedAlternative {
                numbered = value
                name = normalizedBefore
            }
        }

        if let role = role(for: name) {
            return .init(stem: name, role: role, explicitMediaStem: nil,
                         numberedAlternative: numbered, language: language,
                         season: season.number, isSpecialsSeason: season.specials)
        }

        for suffix in ["thumbnail", "thumb", "clearlogo", "backdrop", "fanart", "poster", "logo", "banner"] {
            guard name.hasSuffix("-\(suffix)") else { continue }
            let prefix = String(name.dropLast(suffix.count + 1))
            guard !prefix.isEmpty else { continue }
            let candidateRole: ShareArtworkRole
            if suffix == "thumb" || suffix == "thumbnail" {
                candidateRole = .episodeThumbnail
            } else if let parsed = Self.role(for: suffix) {
                candidateRole = parsed
            } else {
                continue
            }
            return .init(stem: name, role: candidateRole, explicitMediaStem: prefix,
                         numberedAlternative: numbered, language: language,
                         season: season.number, isSpecialsSeason: season.specials)
        }

        // An image with an otherwise unrecognised basename can still be an exact
        // media-stem image. Association fails closed unless it exactly matches one.
        return .init(stem: name, role: .exactStem, explicitMediaStem: name,
                     numberedAlternative: numbered, language: language,
                     season: season.number, isSpecialsSeason: season.specials)
    }

    private static func role(for name: String) -> ShareArtworkRole? {
        switch name {
        case "poster", "folder", "cover", "default", "movie", "show": return .poster
        case "fanart", "backdrop", "background", "art": return .backdrop
        case "landscape", "thumb": return .landscape
        case "clearlogo", "logo": return .logo
        case "banner": return .banner
        case "thumbnail": return .episodeThumbnail
        default: return nil
        }
    }

    private static func seasonFacts(_ value: String) -> (number: Int?, specials: Bool) {
        if value.range(of: #"^season(?:[ _-]?specials|00)(?:[ _-].*)?$"#, options: .regularExpression) != nil {
            return (0, true)
        }
        guard let range = value.range(of: #"^season[ _-]?[0-9]{1,2}"#,
                                      options: .regularExpression) else {
            return (nil, false)
        }
        let match = String(value[range])
        let digits = match.split(whereSeparator: { !$0.isNumber }).last(where: { !$0.isEmpty })
        return (digits.flatMap { Int($0) }, false)
    }
}

struct LocalArtworkCandidate: Sendable, Equatable {
    var relPath: String
    var parentDir: String
    var basename: String
    var facts: ShareArtworkNameFacts
    var size: Int64
    var modifiedAt: Date
    var stableFileID: String?
    var strongETag: String?
    var changeToken: String?
    var isBackdropFolder: Bool
}

enum ShareArtworkInventoryPolicy {
    static let perSubfolderCap = 32

    static func candidates(
        entries: [RemoteFileEntry],
        parentDir: String
    ) -> [LocalArtworkCandidate] {
        let isBackdropFolder = ["backdrops", "extrafanart"].contains(
            (parentDir as NSString).lastPathComponent.lowercased()
        )
        var output: [LocalArtworkCandidate] = []
        for entry in entries where entry.kind == .file {
            guard var facts = ShareArtworkNameParser.parse(entry.name) else { continue }
            // Every still-looking image in these dedicated folders is a backdrop
            // candidate; name validation/probing remains deferred.
            if isBackdropFolder, facts.role == .exactStem { facts.role = .backdrop }
            guard facts.role != .exactStem || facts.explicitMediaStem != nil else { continue }
            let relPath = parentDir.isEmpty ? entry.name : "\(parentDir)/\(entry.name)"
            output.append(.init(
                relPath: relPath, parentDir: parentDir, basename: entry.name, facts: facts,
                size: entry.size ?? 0, modifiedAt: entry.modifiedAt ?? .distantPast,
                stableFileID: entry.stableFileID, strongETag: entry.strongETag,
                changeToken: entry.changeToken, isBackdropFolder: isBackdropFolder
            ))
        }
        if isBackdropFolder {
            output.sort {
                let lhs = $0.relPath.lowercased()
                let rhs = $1.relPath.lowercased()
                return lhs == rhs ? $0.relPath < $1.relPath : lhs < rhs
            }
            return Array(output.prefix(perSubfolderCap))
        }
        return output
    }
}

struct ShareArtworkCatalogAsset: Sendable {
    var relPath: String
    var kind: CatalogAssetKind
    var movieOwnerID: String?
    var seriesKey: String?
    var season: Int?
    var metadataRoot: String?
}

struct ShareArtworkAssociation: Sendable, Equatable {
    var itemID: String
    var placement: ArtworkPlacement
    var artworkRelPath: String
    var rank: Int
}

enum ShareArtworkAssociationPolicy {
    static func associations(
        candidate: LocalArtworkCandidate,
        assets: [ShareArtworkCatalogAsset]
    ) -> [ShareArtworkAssociation] {
        let owner = owner(for: candidate, assets: assets)
        guard let owner else { return [] }
        return placements(role: candidate.facts.role, owner: owner).map {
            .init(
                itemID: owner.id,
                placement: $0.placement,
                artworkRelPath: candidate.relPath,
                rank: baseRank(candidate) + $0.affinity
            )
        }
    }

    private struct Owner {
        var id: String
        var kind: CatalogAssetKind?
        var isSeason: Bool
    }

    private static func owner(for candidate: LocalArtworkCandidate, assets: [ShareArtworkCatalogAsset]) -> Owner? {
        let directParent = candidate.isBackdropFolder
            ? (candidate.parentDir as NSString).deletingLastPathComponent
            : candidate.parentDir
        if let number = candidate.facts.season {
            let series = Set(assets.filter {
                $0.season == number
                    && isSameOrDescendant(
                        ($0.relPath as NSString).deletingLastPathComponent,
                        of: directParent
                    )
            }.compactMap(\.seriesKey))
            if series.count == 1, let key = series.first {
                return .init(id: ShareCatalogID.season(key, number), kind: nil, isSeason: true)
            }
        }
        let exact = candidate.facts.explicitMediaStem?.lowercased()
        if let exact {
            let matching = assets.filter {
                ($0.relPath as NSString).deletingLastPathComponent == directParent
                    && ShareMediaParser.videoStem(($0.relPath as NSString).lastPathComponent).lowercased() == exact
            }
            if matching.count == 1, let asset = matching.first {
                if asset.kind == .movie {
                    return .init(id: asset.movieOwnerID ?? ShareCatalogID.file(asset.relPath), kind: .movie, isSeason: false)
                }
                return .init(id: ShareCatalogID.file(asset.relPath), kind: .episode, isSeason: false)
            }
            guard candidate.isBackdropFolder else { return nil }
        }
        let movies = Set(assets.filter {
            $0.kind == .movie && ($0.relPath as NSString).deletingLastPathComponent == directParent
        }.map { $0.movieOwnerID ?? ShareCatalogID.file($0.relPath) })
        if movies.count == 1, let id = movies.first {
            return .init(id: id, kind: .movie, isSeason: false)
        }
        let roots = Set(assets.filter { $0.metadataRoot == directParent }.compactMap(\.seriesKey))
        if roots.count == 1, let key = roots.first {
            return .init(id: ShareCatalogID.series(key), kind: nil, isSeason: false)
        }
        let seasons = Set(assets.filter {
            ($0.relPath as NSString).deletingLastPathComponent == directParent
        }.compactMap { asset -> String? in
            guard let key = asset.seriesKey, let season = asset.season else { return nil }
            return ShareCatalogID.season(key, season)
        })
        if seasons.count == 1, let id = seasons.first {
            return .init(id: id, kind: nil, isSeason: true)
        }
        return nil
    }

    private static func isSameOrDescendant(_ path: String, of directory: String) -> Bool {
        path == directory || path.hasPrefix(directory.isEmpty ? "" : "\(directory)/")
    }

    private static func placements(
        role: ShareArtworkRole?,
        owner: Owner
    ) -> [(placement: ArtworkPlacement, affinity: Int)] {
        switch role {
        case .exactStem:
            return owner.kind == .episode
                ? [(.episodeThumbnail, 0)]
                : [(owner.isSeason ? .seasonPoster : .poster, 0)]
        case .poster:
            return [(owner.isSeason ? .seasonPoster : .poster, 0)]
        case .backdrop:
            return [(.homeHero, 10), (.detailBackdrop, 0)]
        case .landscape:
            return [(.homeHero, 0), (.detailBackdrop, 10)]
        case .logo: return [(.logo, 0)]
        case .banner: return [(owner.isSeason ? .seasonBanner : .banner, 0)]
        case .episodeThumbnail:
            return owner.kind == .episode ? [(.episodeThumbnail, 0)] : []
        case nil: return []
        }
    }

    private static func baseRank(_ candidate: LocalArtworkCandidate) -> Int {
        let explicit: Int
        if candidate.facts.explicitMediaStem == nil {
            explicit = 20
        } else if candidate.facts.role == .exactStem {
            explicit = 5
        } else {
            explicit = 0
        }
        let numbered = candidate.facts.numberedAlternative.map { 100 + $0 } ?? 0
        let language = candidate.facts.language == nil ? 0 : 10
        return explicit + numbered + language
    }
}

struct ShareArtworkRankedCandidate: Sendable, Equatable {
    var relPath: String
    var rank: Int
}

enum ShareArtworkRankingPolicy {
    static func ordered(_ candidates: [ShareArtworkRankedCandidate], placement: ArtworkPlacement) -> [ShareArtworkRankedCandidate] {
        let sorted = candidates.sorted {
            $0.rank == $1.rank ? $0.relPath.localizedCaseInsensitiveCompare($1.relPath) == .orderedAscending : $0.rank < $1.rank
        }
        return Array(sorted.prefix(16))
    }

    static func distinctDetail(
        home: [ShareArtworkRankedCandidate],
        detail: [ShareArtworkRankedCandidate]
    ) -> [ShareArtworkRankedCandidate] {
        guard let homeID = home.first?.relPath,
              let alternative = detail.firstIndex(where: { $0.relPath != homeID }) else {
            return detail
        }
        var reordered = detail
        reordered.swapAt(0, alternative)
        return reordered
    }
}
