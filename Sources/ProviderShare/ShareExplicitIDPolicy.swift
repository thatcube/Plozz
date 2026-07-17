import Foundation

/// Canonicalization, ambiguity handling, and compatibility-key projection for
/// explicit provider IDs from NFO and filename/folder sources.
enum ShareExplicitIDPolicy {
    static let conflictMarker = "!conflict!"

    static func canonicalize(
        namespace rawNamespace: String,
        value rawValue: String
    ) -> (namespace: String, value: String)? {
        let namespace = canonicalNamespace(rawNamespace)
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if namespace == "imdb" {
            let lower = value.lowercased()
            guard lower.hasPrefix("tt"), lower.count > 2,
                  lower.dropFirst(2).allSatisfy(\.isNumber) else { return nil }
            return ("imdb", lower)
        }
        let isPositiveInteger = value.allSatisfy(\.isNumber) && (Int(value) ?? 0) > 0
        if ["tmdb", "tvdb", "tvmaze", "anilist", "mal", "anidb"].contains(namespace) {
            return isPositiveInteger ? (namespace, value) : nil
        }
        return (namespace, value)
    }

    static func canonicalNamespace(_ raw: String) -> String {
        let normalized = raw.lowercased().trimmingCharacters(in: .whitespaces)
        switch normalized {
        case "imdb", "imdbid", "imdb_id": return "imdb"
        case "tmdb", "tmdbid", "themoviedb": return "tmdb"
        case "tvdb", "tvdbid", "thetvdb": return "tvdb"
        case "tvmaze", "tvmazeid": return "tvmaze"
        case "anilist", "anilistid": return "anilist"
        case "mal", "myanimelist", "myanimelistid": return "mal"
        case "anidb", "anidbid": return "anidb"
        default: return normalized
        }
    }

    static func unambiguous(
        _ candidates: [[String: String]]
    ) -> [String: String] {
        var valuesByNamespace: [String: Set<String>] = [:]
        var conflictedNamespaces = Set<String>()
        for ids in candidates {
            for (namespace, value) in ids {
                let canonicalNamespace = canonicalNamespace(namespace)
                if value == conflictMarker {
                    conflictedNamespaces.insert(canonicalNamespace)
                    continue
                }
                guard let canonical = canonicalize(namespace: namespace, value: value) else {
                    continue
                }
                valuesByNamespace[canonical.namespace, default: []].insert(canonical.value)
            }
        }
        return valuesByNamespace.reduce(into: [:]) { result, entry in
            if !conflictedNamespaces.contains(entry.key),
               entry.value.count == 1,
               let value = entry.value.first {
                result[entry.key] = value
            }
        }
    }

    static func projectedKey(namespace: String) -> String {
        switch namespace {
        case "imdb": return "Imdb"
        case "tmdb": return "Tmdb"
        case "tvdb": return "Tvdb"
        case "tvmaze": return "Tvmaze"
        case "anilist": return "Anilist"
        case "mal": return "Mal"
        case "anidb": return "Anidb"
        default: return namespace
        }
    }
}
