import Foundation

/// Owns the debounce/coalescing lifecycle for ``DetailSnapshotCache``'s periodic
/// least-recently-used prune, and nothing else.
///
/// Why this exists: a snapshot `store` used to enqueue a *fresh directory scan per
/// successful write*. Opening one detail page can persist several snapshots in a
/// short burst (the item, its children, then per-season episodes as they resolve),
/// and rapid back-and-forth navigation persists more. Each of those writes kicked
/// off its own full directory enumeration + `resourceValues` stat of every cached
/// file, so a burst of *N* writes did *N* whole-directory scans even though a single
/// scan at the end would enforce the caps identically.
///
/// This coordinator collapses that: a write asks it to ``schedule()`` a prune, and
/// many requests inside one debounce window coalesce into a single scan. Writes that
/// land while a scan is *running* are naturally serialized behind it on the private
/// serial queue and open **at most one** follow-up window afterwards. The caps are
/// soft (entry/byte budgets), so briefly deferring enforcement by the debounce
/// interval is harmless, and the scan stays entirely off the write path.
///
/// Concurrency: every mutation of `pending` happens on the private serial `queue`,
/// so this is a plain `@unchecked Sendable`. The other stored properties are
/// immutable `let`s and the injected `perform` closure is `@Sendable`.
final class DetailSnapshotPruneCoordinator: @unchecked Sendable {
    private let queue: DispatchQueue
    private let debounce: DispatchTimeInterval
    private let perform: @Sendable () -> Void

    /// The single in-flight *debouncing* prune, if one is currently scheduled. While
    /// this is non-nil a further ``schedule()`` coalesces into it rather than queuing
    /// another scan. Confined to `queue`.
    private var pending: DispatchWorkItem?

    init(
        label: String = "com.thatcube.Plozz.DetailSnapshotCache.prune",
        qos: DispatchQoS = .background,
        debounce: DispatchTimeInterval = .milliseconds(500),
        perform: @escaping @Sendable () -> Void
    ) {
        self.queue = DispatchQueue(label: label, qos: qos)
        self.debounce = debounce
        self.perform = perform
    }

    /// Requests a prune. If a prune is already debouncing, the call coalesces into it
    /// (no additional scan is queued). Requests that arrive while a scan is *running*
    /// wait behind it on `queue`; the first to run afterwards opens exactly one new
    /// debounce window and the rest coalesce, so a burst overlapping a scan produces
    /// at most one follow-up scan.
    func schedule() {
        queue.async { self.scheduleOnQueue() }
    }

    private func scheduleOnQueue() {
        guard pending == nil else { return }
        let item = DispatchWorkItem { [weak self] in self?.fire() }
        pending = item
        queue.asyncAfter(deadline: .now() + debounce, execute: item)
    }

    private func fire() {
        // Runs on `queue`. Clear `pending` *before* running the scan so any writes
        // that arrive during the scan open exactly one fresh window afterwards.
        pending = nil
        perform()
    }

#if DEBUG
    /// Test-only deterministic settle: cancels any debouncing prune and runs it now,
    /// then resumes.
    ///
    /// Because `queue` is serial, every ``schedule()`` enqueued by an
    /// already-completed `store` has executed before this block runs, so `pending`
    /// reflects the fully coalesced window. Awaiting this therefore observes the
    /// settled, post-prune directory without racing the debounce timer (which a bare
    /// serial-queue sentinel would, since the `asyncAfter` work item has not been
    /// dispatched to the queue until its deadline).
    func settleForTesting() async {
        await withCheckedContinuation { continuation in
            queue.async {
                if let pending = self.pending {
                    pending.cancel()
                    self.pending = nil
                    self.perform()
                }
                continuation.resume()
            }
        }
    }
#endif
}
