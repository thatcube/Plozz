import CoreModels
import SearchIndexKit

enum SearchIndexSourceBuilder {
    static func providerUserKeys(
        accounts: [ResolvedAccount],
        plexHomeUsers: [String: String],
        profile: Profile
    ) -> [String: String] {
        Dictionary(
            uniqueKeysWithValues: accounts.map { resolved in
                let key: String
                if resolved.account.server.provider == .plex {
                    key = plexHomeUsers[resolved.account.id]
                        ?? profile.homeUserBinding(
                            forPlexAccount: resolved.account.id
                        )?.homeUserID
                        ?? resolved.account.id
                } else {
                    key = resolved.account.id
                }
                return (resolved.account.id, key)
            }
        )
    }

    static func build(
        accounts: [ResolvedAccount],
        disabledLibraryKeys: Set<String>,
        plexHomeUsers: [String: String],
        profile: Profile
    ) async -> [SearchIndexSource] {
        await withTaskGroup(of: SearchIndexSource?.self) { group in
            for resolved in accounts {
                group.addTask {
                    guard let catalogProvider =
                            resolved.provider as? any SearchCatalogProviding,
                          let libraries = try? await resolved.provider.libraries()
                    else { return nil }
                    let visibleLibraries = libraries.compactMap {
                        library -> SearchIndexLibrarySource? in
                        guard !library.isMusic,
                              !disabledLibraryKeys.contains(
                                "\(resolved.account.id):\(library.id)"
                              ) else {
                            return nil
                        }
                        switch library.kind {
                        case .movie:
                            return SearchIndexLibrarySource(
                                libraryID: library.id,
                                kinds: [.movie]
                            )
                        case .series:
                            return SearchIndexLibrarySource(
                                libraryID: library.id,
                                kinds: [.series, .episode]
                            )
                        default:
                            return nil
                        }
                    }
                    let providerUserKey = providerUserKeys(
                        accounts: [resolved],
                        plexHomeUsers: plexHomeUsers,
                        profile: profile
                    )[resolved.account.id] ?? resolved.account.id
                    return SearchIndexSource(
                        accountID: resolved.account.id,
                        providerUserKey: providerUserKey,
                        provider: catalogProvider,
                        libraries: visibleLibraries
                    )
                }
            }
            var sources: [SearchIndexSource] = []
            for await source in group {
                if let source { sources.append(source) }
            }
            return sources.sorted { $0.accountID < $1.accountID }
        }
    }
}
