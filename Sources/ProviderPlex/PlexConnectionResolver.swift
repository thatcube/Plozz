import Foundation
import Synchronization
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
public final class PlexConnectionResolver: Sendable {
    /// Fetches a fresh, reachable-ordered candidate list from plex.tv (used only
    /// when none of the known candidates respond).
    public typealias Refresh = @Sendable () async -> [URL]

    private let probe: HTTPClient
    private let deviceProfile: PlexDeviceProfile
    private let token: String
    private let refresh: Refresh?
    private let onReachable: (@Sendable (URL) -> Void)?

    /// Everything this resolver mutates, held INSIDE the mutex.
    ///
    /// Bundled rather than left as loose properties beside an `NSLock` so the
    /// type system enforces what a convention used to: there is no way to read
    /// or write any of it without holding the lock, because there is no way to
    /// name it from outside `withLock`, so the lock cannot be forgotten at a use
    /// site.
    ///
    /// Note what this does NOT buy: `Mutex` is declared `@unchecked Sendable`
    /// unconditionally, with no `Value: Sendable` requirement, so putting a
    /// non-`Sendable` field in `State` still compiles and is still unsound. The
    /// `@unchecked` moved into `Mutex`; it was not eliminated. Keep every field
    /// below `Sendable` (or provably value-copied out) by hand.
    private struct State {
        var candidates: [URL]
        var cached: URL?
        var inFlight: Task<URL, Never>?
        /// Set once a reported failure clears the cache, or a full probe sweep
        /// finds nothing reachable (the persisted seed itself was probed and
        /// failed). While set, the last-known-good `reachableSeed` is no longer
        /// trusted for the synchronous `hasConfirmedReachableConnection` read,
        /// so locality falls back to `.unknown` until a fresh probe re-confirms
        /// a live connection. Cleared by `store` the moment any probe succeeds.
        /// (r8-stale-reachability-locality)
        var reachabilityInvalidated = false
    }

    private let state: Mutex<State>
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
        state = Mutex(State(candidates: Self.prioritized(seeded)))
    }

    /// Best-known base URL available synchronously: the cached reachable URL, then
    /// the last-known-good reachable seed (persisted across launches), then the
    /// most-preferred candidate if nothing has been probed yet. Used by the
    /// synchronous URL builders (artwork, stream/transcode URLs) and the
    /// `connectionLocality` read, which normally run only after a `resolved()`
    /// request has already populated `cached`.
    ///
    /// Preferring `reachableSeed` over `candidates[0]` before the first probe
    /// matters for the rare synchronous read that races ahead of resolution (e.g. a
    /// detail page classifying locality at first paint): `candidates[0]` is the
    /// highest-*priority* address, which — because a server advertises its own LAN
    /// address even to remote clients — can be a local-looking URL that isn't
    /// actually reachable, whereas the seed is by definition an address that worked
    /// last launch. The live probe still corrects both the moment it settles.
    public var current: URL {
        state.withLock { $0.cached ?? reachableSeed ?? $0.candidates[0] }
    }

    /// True when the resolver has a connection whose locality can be trusted: a
    /// probe-confirmed `cached` URL or a persisted last-known-good `reachableSeed`
    /// (an address that demonstrably worked) that has **not** since been
    /// invalidated by a reported failure or a failed probe sweep. When neither
    /// holds, `current` falls back to the most-preferred but **unproven** candidate
    /// — and because a Plex server advertises its own LAN address even to remote
    /// clients, that guess can be a local-looking URL that isn't actually
    /// reachable. Best-source selection must treat locality as `.unknown` until
    /// this is true, or a dead LAN-shaped guess would wrongly win as `.local`.
    ///
    /// Crucially this drops back to `false` after a failure until a fresh probe
    /// re-confirms: a server that dies mid-session must stop advertising itself as
    /// a confirmed-local candidate, so a genuinely reachable remote twin can take
    /// over playback instead of the selector clinging to the now-dead LAN box.
    public var hasConfirmedReachableConnection: Bool {
        state.withLock { state in
            if state.cached != nil { return true }
            return !state.reachabilityInvalidated && reachableSeed != nil
        }
    }

    /// `current`, but only when its locality can be trusted — the confirmation
    /// check and the URL it guards read from a SINGLE acquisition of the lock.
    ///
    /// Callers must NOT compose this from `hasConfirmedReachableConnection` and
    /// `current` separately: a `reportFailure` landing between those two reads
    /// clears `cached`, so the guard passes on the old confirmed address while
    /// `current` returns the unproven `candidates[0]` — which is exactly the dead
    /// LAN-shaped guess the guard exists to reject. (r6-plex-unreachable-local)
    public var confirmedBaseURL: URL? {
        state.withLock { state in
            if let cached = state.cached { return cached }
            guard !state.reachabilityInvalidated else { return nil }
            return reachableSeed
        }
    }

    /// The base URL to use for the next request. Probes for a reachable
    /// connection on first use (and after a reported failure), caching the
    /// result; concurrent callers share a single in-flight resolution.
    public func resolved() async -> URL {
        // Decide under the lock, await outside it.
        //
        // The lock was previously taken and released by hand across several
        // exit paths. That was correct — every `await` was reached only after an
        // `unlock()` — but correctness rested on reading the whole function and
        // checking each branch, and `NSLock.lock()` is `@available(*, noasync)`
        // precisely because getting that wrong blocks a cooperative-pool thread
        // and Swift has very few of those. Deciding first and suspending after
        // makes it structural: there is no `await` inside the critical section
        // to get wrong, and a future branch cannot introduce one.
        enum Decision {
            case ready(URL)
            case join(Task<URL, Never>)
            case start(Task<URL, Never>)
        }

        let decision: Decision = state.withLock { state in
            // Fast path: a fixed URL (or an already-cached choice) needs no probe.
            if let cached = state.cached { return .ready(cached) }
            if !(state.candidates.count > 1 || refresh != nil) {
                let only = state.candidates[0]
                state.cached = only
                return .ready(only)
            }
            if let inFlight = state.inFlight { return .join(inFlight) }
            // The task clears `inFlight` itself, BEFORE it publishes its result.
            //
            // Clearing it in the `.start` branch below instead meant only the
            // starter cleared it, and only after being woken — so a joiner that
            // resumed first could report the resolved URL as failed and
            // immediately re-enter `resolved()`, find the completed task still
            // stored, and be handed the very URL it had just reported dead.
            // `PlexClient` calls `reportFailure` and `resolved()` back to back
            // on exactly that path, so self-healing onto a live connection
            // stopped happening: the retry matched the address that had failed.
            let task = Task<URL, Never> {
                let url = await self.performResolve()
                self.state.withLock { $0.inFlight = nil }
                return url
            }
            state.inFlight = task
            return .start(task)
        }

        switch decision {
        case let .ready(url):
            return url
        case let .join(task):
            return await task.value
        case let .start(task):
            return await task.value
        }
    }

    /// Reports that `url` failed to respond. If it was the cached choice, the
    /// cache is cleared so the next `resolved()` re-probes (and re-heals onto a
    /// reachable connection), and reachability confidence is invalidated so the
    /// synchronous locality read reports `.unknown` until a fresh probe confirms a
    /// live connection (a dead server must not keep winning as `.local`).
    public func reportFailure(_ url: URL) {
        state.withLock { state in
            if state.cached == url {
                state.cached = nil
                state.reachabilityInvalidated = true
            }
        }
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
        // caching, so the next attempt re-probes once connectivity returns. The
        // persisted seed was just probed (within its rank group) and did not
        // answer, so invalidate reachability confidence — the synchronous locality
        // read must now report `.unknown` rather than trusting a stale seed.
        return state.withLock { state in
            state.reachabilityInvalidated = true
            return state.candidates[0]
        }
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
        state.withLock { $0.candidates }
    }

    private func replaceCandidates(_ urls: [URL]) {
        state.withLock { $0.candidates = urls }
    }

    private func store(_ url: URL) {
        // The callback stays OUTSIDE the critical section, as it was: invoking
        // it while holding the lock hands an unknown caller the chance to
        // re-enter this resolver and deadlock.
        state.withLock { state in
            state.cached = url
            state.reachabilityInvalidated = false
        }
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
private final class ProbeRace: Sendable {
    private struct State {
        var remaining: Int
        var finished = false
        var continuation: CheckedContinuation<URL?, Never>?
        var tasks: [Task<Void, Never>] = []
    }

    /// What to do once the lock is released. Cancelling losers and resuming the
    /// continuation must both happen OUTSIDE the critical section — resuming a
    /// continuation runs the awaiting code, which is an unbounded amount of work
    /// to do while holding a lock, and cancellation can call back in. The
    /// hand-written version got this right by unlocking on each path; returning
    /// the follow-up work makes it impossible for a new path to forget.
    private struct Outcome {
        var losers: [Task<Void, Never>] = []
        var continuation: CheckedContinuation<URL?, Never>?
        var result: URL?
    }

    private let state: Mutex<State>

    init(remaining: Int, continuation: CheckedContinuation<URL?, Never>) {
        state = Mutex(State(remaining: remaining, continuation: continuation))
    }

    func track(_ task: Task<Void, Never>) {
        let alreadyFinished = state.withLock { state -> Bool in
            if state.finished { return true }
            state.tasks.append(task)
            return false
        }
        if alreadyFinished { task.cancel() }
    }

    func report(_ url: URL?) {
        let outcome: Outcome? = state.withLock { state in
            guard !state.finished else { return nil }
            if let url {
                state.finished = true
                defer { state.continuation = nil; state.tasks = [] }
                return Outcome(
                    losers: state.tasks,
                    continuation: state.continuation,
                    result: url
                )
            }
            state.remaining -= 1
            guard state.remaining <= 0 else { return nil }
            state.finished = true
            defer { state.continuation = nil; state.tasks = [] }
            return Outcome(continuation: state.continuation, result: nil)
        }
        guard let outcome else { return }
        outcome.losers.forEach { $0.cancel() }
        outcome.continuation?.resume(returning: outcome.result)
    }
}
