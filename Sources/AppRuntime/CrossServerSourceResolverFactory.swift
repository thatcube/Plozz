import CoreModels
import Foundation

private func searchWithDeadline(
    _ provider: any MediaProvider,
    query: String,
    limit: Int,
    seconds: Double
) async -> [MediaItem] {
    let searchTask = Task {
        (try? await provider.search(query: query, limit: limit)) ?? []
    }
    // Dispatch keeps the deadline responsive even when cooperative tasks are saturated.
    let timeout = DispatchWorkItem { searchTask.cancel() }
    DispatchQueue.global(qos: .utility).asyncAfter(
        deadline: .now() + seconds,
        execute: timeout
    )
    let result = await searchTask.value
    timeout.cancel()
    return result
}

/// Builds the shared on-demand cross-server source probe used by both app shells.
public func crossServerSourceResolver(
    in accounts: [ResolvedAccount],
    identitySources: @escaping @Sendable (MediaItem) -> [MediaSourceRef]
) -> (@Sendable (MediaItem) async -> [MediaSourceRef])? {
    guard !accounts.isEmpty else { return nil }
    let serverInfo = accounts.sourceServerInfo()
    let orderedAccountIDs = accounts.map(\.account.id)
    let providersByAccountID: [String: any MediaProvider] = Dictionary(
        accounts.map { ($0.account.id, $0.provider) },
        uniquingKeysWith: { first, _ in first }
    )
    return { primary in
        var sources = identitySources(primary)
        var seen = Set(sources.map(\.id))
        let resolved = await CrossServerSourceResolver.resolve(
            primary: primary,
            otherAccountIDs: orderedAccountIDs,
            search: { accountID, query in
                guard let provider = providersByAccountID[accountID] else { return [] }
                return await searchWithDeadline(
                    provider,
                    query: query,
                    limit: 25,
                    seconds: 4
                )
            },
            serverInfo: { serverInfo[$0] }
        )

        let resolvedIDs = Set(resolved.map(\.id))
        sources.removeAll { resolvedIDs.contains($0.id) }
        seen = resolvedIDs
        var merged = resolved
        for source in sources where seen.insert(source.id).inserted {
            merged.append(source)
        }
        return merged
    }
}

/// A cross-account library search for the Related row: one query fanned out to
/// every signed-in server, results pooled.
///
/// Pooled rather than per-account because a related title only has to exist
/// *somewhere* the viewer can reach. Which server holds it is the detail page's
/// problem once they open it, not this row's.
///
/// The same short deadline as the cross-server probe applies: a cold or unreachable
/// server must not hold up a row that is, by design, supplementary.
public func relatedTitleLibrarySearch(
    in accounts: [ResolvedAccount]
) -> (@Sendable (String, Int) async -> [MediaItem])? {
    guard !accounts.isEmpty else { return nil }
    let entries = accounts.map { ($0.account.id, $0.provider) }
    return { query, limit in
        await withTaskGroup(of: [MediaItem].self) { group in
            for (accountID, provider) in entries {
                group.addTask {
                    await searchWithDeadline(provider, query: query, limit: limit, seconds: 4)
                        .map { $0.taggingSource(accountID) }
                }
            }
            var pooled: [MediaItem] = []
            // Scoped by account, because an item id is provider-LOCAL: two servers
            // routinely use the same raw id for unrelated titles, so pooling on id
            // alone let one server's fuzzy hit suppress another's correct one — and
            // which survived depended on which search happened to finish first.
            var seen = Set<String>()
            for await hits in group {
                for hit in hits {
                    let key = "\(hit.sourceAccountID ?? "_"):\(hit.id)"
                    if seen.insert(key).inserted { pooled.append(hit) }
                }
            }
            return pooled
        }
    }
}
