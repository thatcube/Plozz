import Foundation
import CoreModels
import CoreNetworking

/// Resolves and caches the working base URL for a Plex server, self-healing when
/// the chosen connection stops responding.
///
/// Plex advertises *every* address a server is bound to (LAN, remote, relay, even
/// container-bridge gateways). The address that worked when an account was added
/// can later become unreachable — the server moves networks, its LAN IP changes,
/// a Docker gateway gets advertised as "local", relay flips on/off. This resolver
/// probes the known candidate connections and keeps the first that answers,
/// re-resolving transparently after a failure and, as a last resort, asking
/// plex.tv for a fresh connection list. Callers never see the churn: browsing
/// "just works" against whatever path is currently reachable.
///
/// A resolver with a single candidate and no refresh has nothing to choose
/// between, so it returns that URL immediately without any network probe — this
/// keeps the fixed-URL path (and unit tests) zero-cost and offline-safe.
public final class PlexConnectionResolver: @unchecked Sendable {
    /// Fetches a fresh, reachable-ordered candidate list from plex.tv (used only
    /// when none of the known candidates respond).
    public typealias Refresh = @Sendable () async -> [URL]

    private let probe: HTTPClient
    private let deviceProfile: PlexDeviceProfile
    private let token: String
    private let refresh: Refresh?

    private let lock = NSLock()
    private var candidates: [URL]
    private var cached: URL?
    private var inFlight: Task<URL, Never>?

    public init(
        candidates: [URL],
        deviceProfile: PlexDeviceProfile,
        token: String,
        probe: HTTPClient = URLSessionHTTPClient(session: .plozzDiscovery),
        refresh: Refresh? = nil
    ) {
        precondition(!candidates.isEmpty, "PlexConnectionResolver requires at least one candidate URL")
        self.candidates = candidates
        self.deviceProfile = deviceProfile
        self.token = token
        self.probe = probe
        self.refresh = refresh
    }

    /// Best-known base URL available synchronously: the cached reachable URL, or
    /// the most-preferred candidate if probing hasn't settled. Used by the
    /// synchronous URL builders (artwork, stream/transcode URLs), which only run
    /// after a `resolved()` request has already populated the cache.
    public var current: URL {
        lock.lock(); defer { lock.unlock() }
        return cached ?? candidates[0]
    }

    /// The base URL to use for the next request. Probes for a reachable
    /// connection on first use (and after a reported failure), caching the
    /// result; concurrent callers share a single in-flight resolution.
    public func resolved() async -> URL {
        // Fast path: a fixed URL (or an already-cached choice) needs no probe.
        lock.lock()
        if let cached {
            lock.unlock()
            return cached
        }
        if !(candidates.count > 1 || refresh != nil) {
            let only = candidates[0]
            cached = only
            lock.unlock()
            return only
        }
        if let inFlight {
            lock.unlock()
            return await inFlight.value
        }
        let task = Task<URL, Never> { await self.performResolve() }
        inFlight = task
        lock.unlock()

        let url = await task.value
        lock.lock()
        inFlight = nil
        lock.unlock()
        return url
    }

    /// Reports that `url` failed to respond. If it was the cached choice, the
    /// cache is cleared so the next `resolved()` re-probes (and re-heals onto a
    /// reachable connection).
    public func reportFailure(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        if cached == url { cached = nil }
    }

    private func performResolve() async -> URL {
        let snapshot = currentCandidates()
        if let reachable = await firstReachable(among: snapshot) {
            store(reachable)
            return reachable
        }
        // Nothing we know about answered. Ask plex.tv for the current connection
        // list (the server may have moved) and probe that.
        if let refresh {
            let fresh = await refresh()
            if !fresh.isEmpty {
                replaceCandidates(fresh)
                if let reachable = await firstReachable(among: fresh) {
                    store(reachable)
                    return reachable
                }
            }
        }
        // Still nothing reachable: return the most-preferred candidate WITHOUT
        // caching, so the next attempt re-probes once connectivity returns.
        return currentCandidates()[0]
    }

    /// The first candidate that answers a lightweight `/identity` probe, or `nil`
    /// if none respond within the probe window. Candidates are probed in
    /// parallel and the **first to answer wins** — the remaining probes are
    /// cancelled immediately so a dead candidate (e.g. an unreachable LAN/Docker
    /// address that only fails after a connect timeout) never stalls resolution.
    private func firstReachable(among urls: [URL]) async -> URL? {
        await withTaskGroup(of: URL?.self) { group in
            for url in urls {
                group.addTask {
                    let endpoint = Endpoint(path: "/identity", headers: self.deviceProfile.headers(token: self.token))
                    do {
                        _ = try await self.probe.send(endpoint, baseURL: url)
                        return url
                    } catch {
                        return nil
                    }
                }
            }
            for await result in group {
                if let result {
                    group.cancelAll()
                    return result
                }
            }
            return nil
        }
    }

    private func currentCandidates() -> [URL] {
        lock.lock(); defer { lock.unlock() }
        return candidates
    }

    private func replaceCandidates(_ urls: [URL]) {
        lock.lock(); defer { lock.unlock() }
        candidates = urls
    }

    private func store(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        cached = url
    }
}
