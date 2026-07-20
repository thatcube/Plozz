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
