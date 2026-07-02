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
/// Candidates are probed **in parallel and the first to answer wins** — the
/// resolution returns the instant a reachable address replies, without waiting
/// for the slow/dead candidates (unreachable LAN, Docker bridges, dead relay IPs)
/// to time out. Candidates are also probed in a sensible order (LAN before
/// container-bridge/public addresses), and the last-known-good connection is
/// persisted across launches so a warm server resolves immediately.
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
    private let onReachable: (@Sendable (URL) -> Void)?

    private let lock = NSLock()
    private var candidates: [URL]
    private var cached: URL?
    private var inFlight: Task<URL, Never>?
    /// The last-known-good connection persisted across launches, if any. Probed
    /// first *within its rank group* so a warm server re-confirms on a single
    /// probe and the winner among otherwise-equivalent same-rank candidates is
    /// deterministic. It never competes across ranks, so locality still wins.
    private let reachableSeed: URL?

    public init(
        candidates: [URL],
        deviceProfile: PlexDeviceProfile,
        token: String,
        probe: HTTPClient = URLSessionHTTPClient(session: .plozzDiscovery),
        refresh: Refresh? = nil,
        reachableSeed: URL? = nil,
        onReachable: (@Sendable (URL) -> Void)? = nil
    ) {
        precondition(!candidates.isEmpty, "PlexConnectionResolver requires at least one candidate URL")
        self.deviceProfile = deviceProfile
        self.token = token
        self.probe = probe
        self.refresh = refresh
        self.onReachable = onReachable
        self.reachableSeed = reachableSeed
        // Seed with the last-known-good connection (persisted across launches) so
        // a previously-reachable server resolves on the first probe instead of
        // re-discovering through dead/stale addresses.
        let seeded = reachableSeed.map { [$0] + candidates } ?? candidates
        self.candidates = Self.prioritized(seeded)
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
                let ordered = Self.prioritized(fresh)
                replaceCandidates(ordered)
                if let reachable = await firstReachable(among: ordered) {
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
    /// if none respond — **locality-tiered, then rank-ordered within a tier**:
    /// same-LAN candidates are tried before a less-local tier (unknown hostname,
    /// then remote / Tailscale / relay), and *within* the local tier a real home
    /// LAN address (192.168/10) is tried before a container-bridge address
    /// (172.16/12) that shares the same RFC1918 `.local` classification. This
    /// guarantees a reachable LAN address is chosen over a reachable remote *or*
    /// Docker-bridge one even when the other path happens to answer first, which
    /// is the whole point of locality-first playback (a title on both the local
    /// box and the sister's Tailscale server must stream from the local box, and
    /// the LAN address must win over the machine's own Docker gateway). Within a
    /// single rank group the **first to answer wins** and losing probes are
    /// cancelled, so a dead candidate never stalls behind its connect timeout.
    private func firstReachable(among urls: [URL]) async -> URL? {
        guard !urls.isEmpty else { return nil }
        let byTier = Dictionary(grouping: urls) { SourceLocalityClassifier.classify(url: $0) }
        for tier in [SourceLocality.local, .unknown, .remote] {
            guard let tierURLs = byTier[tier], !tierURLs.isEmpty else { continue }
            // The coarse locality tier can't distinguish a real LAN address from a
            // Docker-bridge address (both are RFC1918 `.local`), so racing the
            // whole tier makes the winner depend on which probe answers first —
            // non-deterministic under load. Sub-group by the finer connection rank
            // and probe rank groups in order so the preferred address wins
            // deterministically; equally-ranked candidates still race for liveness.
            let byRank = Dictionary(grouping: tierURLs) { Self.rank($0) }
            for rank in byRank.keys.sorted() {
                guard let group = byRank[rank], !group.isEmpty else { continue }
                // Prefer the last-known-good seed within its rank group: probe it
                // first so a warm server re-confirms on a single probe and the
                // winner among equivalent same-rank candidates is deterministic
                // (a concurrent race would otherwise pick whichever probe answers
                // first). Falls through to racing the rest only if the seed is
                // now stale/unreachable.
                if let seed = reachableSeed,
                   group.contains(where: { $0.absoluteString == seed.absoluteString }) {
                    if await probeReachable(seed) { return seed }
                    let rest = group.filter { $0.absoluteString != seed.absoluteString }
                    if !rest.isEmpty, let reachable = await raceReachable(among: rest) { return reachable }
                    continue
                }
                if let reachable = await raceReachable(among: group) { return reachable }
            }
        }
        return nil
    }

    /// Races every URL in one locality tier concurrently, resuming with the first
    /// to answer (cancelling the rest) or `nil` when none in the tier respond.
    private func raceReachable(among urls: [URL]) async -> URL? {
        guard urls.count > 1 else {
            return await probeReachable(urls[0]) ? urls[0] : nil
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            let race = ProbeRace(remaining: urls.count, continuation: continuation)
            for url in urls {
                let task = Task { [weak self] in
                    let reachable = await self?.probeReachable(url) ?? false
                    race.report(reachable ? url : nil)
                }
                race.track(task)
            }
        }
    }

    private func probeReachable(_ url: URL) async -> Bool {
        let endpoint = Endpoint(path: "/identity", headers: deviceProfile.headers(token: token))
        do {
            _ = try await probe.send(endpoint, baseURL: url)
            return true
        } catch {
            return false
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
        lock.lock()
        cached = url
        lock.unlock()
        onReachable?(url)
    }

    // MARK: Candidate ordering

    /// De-duplicates and orders candidates so the most-likely-reachable address
    /// is probed first: private LAN (192.168/10) before "other" hosts (relay
    /// hostnames, Tailscale), before container-bridge ranges (172.16–31) and bare
    /// public IPs. Ordering only — every candidate is still probed, so a server
    /// reachable only via an unusual path is still found.
    static func prioritized(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        let unique = urls.filter { seen.insert($0.absoluteString).inserted }
        return unique.enumerated()
            .sorted { lhs, rhs in
                let rl = rank(lhs.element), rr = rank(rhs.element)
                if rl != rr { return rl < rr }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private static func rank(_ url: URL) -> Int {
        guard let octets = leadingIPv4(url.host) else {
            return 2 // hostname (relay / Tailscale / manually-entered) — medium priority
        }
        switch (octets[0], octets[1]) {
        case (192, 168), (10, _):
            return 0 // home LAN — try first
        case (172, 16...31):
            return 3 // 172.16/12 — almost always a Docker bridge on a home network
        default:
            return 4 // public / relay address
        }
    }

    /// Extracts the leading IPv4 address from either a bare-IP host
    /// (`192.168.68.71`) or a plex.direct host (`192-168-68-71.<hash>.plex.direct`).
    private static func leadingIPv4(_ host: String?) -> [Int]? {
        guard let host else { return nil }
        let firstLabel = host.split(separator: ".").first.map(String.init) ?? host
        for separator in [".", "-"] as [Character] {
            let parts = (separator == "." ? host : firstLabel).split(separator: separator).map(String.init)
            if parts.count == 4, let octets = octetsIfValid(parts) { return octets }
        }
        return nil
    }

    private static func octetsIfValid(_ parts: [String]) -> [Int]? {
        let octets = parts.compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return nil }
        return octets
    }
}

/// Coordinates a set of concurrent reachability probes, resuming its continuation
/// the instant the first probe succeeds (cancelling the rest) or once every probe
/// has failed. Thread-safe; resumes its continuation exactly once.
private final class ProbeRace: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    private var finished = false
    private var continuation: CheckedContinuation<URL?, Never>?
    private var tasks: [Task<Void, Never>] = []

    init(remaining: Int, continuation: CheckedContinuation<URL?, Never>) {
        self.remaining = remaining
        self.continuation = continuation
    }

    func track(_ task: Task<Void, Never>) {
        lock.lock()
        if finished {
            lock.unlock()
            task.cancel()
        } else {
            tasks.append(task)
            lock.unlock()
        }
    }

    func report(_ url: URL?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        if let url {
            finished = true
            let cont = continuation; continuation = nil
            let losers = tasks; tasks = []
            lock.unlock()
            losers.forEach { $0.cancel() }
            cont?.resume(returning: url)
            return
        }
        remaining -= 1
        if remaining <= 0 {
            finished = true
            let cont = continuation; continuation = nil
            tasks = []
            lock.unlock()
            cont?.resume(returning: nil)
            return
        }
        lock.unlock()
    }
}
