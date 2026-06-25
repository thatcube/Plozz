import Foundation

/// Global gate for *background* detail-page enrichment (cross-server discovery,
/// trailer resolution, alternate-source fetches).
///
/// ## Why this exists
/// Each detail open fans out background network work — most expensively a
/// cross-server search to *every* other server. With nothing bounding it, tapping
/// quickly through a dozen titles leaves a dozen of these fan-outs churning the
/// small tvOS Swift **cooperative thread pool** at once. Once that pool is
/// saturated, even `Task.sleep`-based timeouts and task cancellation stop firing
/// promptly (their continuations can't get a thread) — so per-request deadlines
/// become useless and the whole app stalls for tens of seconds until the backlog
/// drains. (Observed: three requests to three different hosts — including a fast
/// LAN server — all completing at the exact same instant after 33s.)
///
/// This scheduler prevents the flood at the source with two mechanisms:
/// 1. **Generation skipping** — opening a new detail page bumps the generation;
///    work tagged with an older generation is dropped *before* it hits the
///    network, so rapid tap-through collapses to just the page you land on.
/// 2. **Bounded concurrency** — at most ``maxConcurrent`` enrichment operations
///    run at once, app-wide, so the cooperative pool is never flooded and
///    foreground work (the user-blocking `provider.item` fetch) always finds a
///    thread.
public actor EnrichmentScheduler {
    public static let shared = EnrichmentScheduler()

    /// Max concurrent background-enrichment operations app-wide. Deliberately
    /// small: enrichment is never user-blocking, so a tight cap keeps the
    /// cooperative pool free for foreground work without starving the picker /
    /// trailer button (which still fill in within a beat once a slot frees).
    private let maxConcurrent: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var generation: UInt64 = 0

    public init(maxConcurrent: Int = 2) {
        self.maxConcurrent = max(1, maxConcurrent)
    }

    /// Marks a new active detail page. Returns the token enrichment for that page
    /// should carry; any work tagged with an older token is now stale.
    public func bumpGeneration() -> UInt64 {
        generation &+= 1
        return generation
    }

    /// Whether `token` is still the current generation.
    public func isCurrent(_ token: UInt64) -> Bool { token == generation }

    /// Runs `operation` bounded to ``maxConcurrent`` concurrency, but only while
    /// `token` is still the current generation. Returns `nil` (without running
    /// `operation`) if the page was superseded either before acquiring a slot or
    /// while waiting for one — so superseded pages never hit the network.
    public func run<T: Sendable>(
        token: UInt64,
        _ operation: @Sendable () async -> T
    ) async -> T? {
        guard token == generation else { return nil }
        await acquire()
        defer { release() }
        // Re-check after potentially waiting for a slot: the user may have moved
        // on while we were queued.
        guard token == generation else { return nil }
        return await operation()
    }

    private func acquire() async {
        if running < maxConcurrent {
            running += 1
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
        // Resumed by `release()`, which handed its slot directly to us.
    }

    private func release() {
        if waiters.isEmpty {
            running -= 1
        } else {
            // Hand the slot straight to the next waiter; `running` stays put.
            waiters.removeFirst().resume()
        }
    }
}
