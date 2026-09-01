import Foundation

/// A small, reusable async concurrency gate: caps how many tasks may be inside a
/// critical async section at once (a counting semaphore for structured
/// concurrency).
///
/// Background fan-outs — season prewarm, loose-thumbnail prefetch, artwork
/// resolution — otherwise spawn an unbounded number of detached download tasks
/// that flood the shared URLSession connection pool and the small tvOS
/// cooperative thread pool, starving whatever the user is actually looking at.
/// Wrapping each unit of that background work in `run` bounds the fan-out to
/// `limit` concurrent operations so it self-throttles instead of swamping
/// foreground work.
///
/// `run` is `nonisolated`, so the wrapped `operation` runs on its own task — it
/// is *not* serialized onto this actor's executor. Only the cheap permit
/// bookkeeping (`acquire`/`release`) touches the actor.
///
/// Operations should be cancellation-tolerant: a permit always handed to the
/// next waiter on `release`, so a cancelled waiter still resumes (and runs its —
/// idempotent — operation) rather than leaking the permit. Use only for
/// best-effort background work, never to gate a user-blocking path.
public actor ConcurrencyLimiter {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var available: Int
    private var waiters: [Waiter] = []

    /// - Parameter limit: maximum number of concurrent operations (clamped to ≥1).
    public init(limit: Int) {
        self.available = max(1, limit)
    }

    private func acquire(cancellable: Bool = false) async -> Bool {
        if cancellable, Task.isCancelled { return false }
        if available > 0 {
            available -= 1
            return true
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation {
                (continuation: CheckedContinuation<Bool, Never>) in
                if cancellable, Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiters.append(
                        Waiter(id: id, continuation: continuation)
                    )
                }
            }
        } onCancel: {
            guard cancellable else { return }
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }

    private func release() {
        if waiters.isEmpty {
            available += 1
        } else {
            // Hand the just-freed permit directly to the longest-waiting task
            // (FIFO) so permits never leak and the count stays balanced.
            waiters.removeFirst().continuation.resume(returning: true)
        }
    }

    /// Runs `operation` once a permit is free, releasing the permit afterwards so
    /// at most `limit` operations run concurrently. The operation executes off
    /// this actor's executor.
    public nonisolated func run<T: Sendable>(_ operation: @Sendable () async -> T) async -> T {
        _ = await acquire()
        let result = await operation()
        await release()
        return result
    }

    /// Throwing variant of ``run(_:)``. Releases the permit whether `operation`
    /// returns or throws, so a thrown error never leaks the permit (which would
    /// permanently shrink the gate). Used to serialize fallible background work
    /// such as YouTubeKit's JavaScriptCore stream extraction.
    public nonisolated func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        _ = await acquire()
        do {
            let result = try await operation()
            await release()
            return result
        } catch {
            await release()
            throw error
        }
    }

    /// Cancellation-aware variant for queued work. Returns `false` without
    /// starting `operation` when cancellation happens while waiting for a permit.
    public nonisolated func runUnlessCancelled(
        _ operation: @Sendable () async -> Void
    ) async -> Bool {
        guard await acquire(cancellable: true) else { return false }
        await operation()
        await release()
        return true
    }
}
