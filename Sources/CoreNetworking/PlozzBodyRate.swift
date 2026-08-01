import Foundation

/// Counts how often specific view bodies run, and reports the RATE once a second.
///
/// The detail-page hang produces tens of thousands of body evaluations with no
/// other telemetry at all — the main thread is saturated, so anything scheduled
/// (a `Task`, a timer, the stall probe) simply never runs and the log goes quiet
/// exactly when it matters most. A counter incremented synchronously inside the
/// body is the one thing that still records under those conditions.
///
/// It also answers the question the render COUNTS could not. A capture showed
/// HomeTab, ItemDetailView and SeriesDetailView churning in a 1:1:1 ratio, which
/// looked like the detail page driving the cycle — but the hang also happens with
/// no detail page open at all, so the detail views were passengers, not drivers.
/// Rates per view, sampled every second, separate the two: whichever view is
/// spinning on its own is the one to chase.
///
/// The 1/s emit is not a nicety. Logging per event during a storm is itself
/// enough to saturate the main thread; doing that inside a view body already
/// turned one capture in this investigation into a jetsam kill. Everything on the
/// hot path here is an integer increment and one clock comparison.
@MainActor
public enum PlozzBodyRate {
    private static var counts: [String: Int] = [:]
    private static var totals: [String: Int] = [:]
    private static var lastEmit = ContinuousClock.now
    /// Emitted once when a rate appears that no legitimate interaction produces,
    /// so the onset is timestamped even if the rate-limited line is delayed.
    private static var warned = false

    /// Records one body evaluation for `label`. Safe to call from a view body.
    public static func tick(_ label: String) {  // l10n:content — developer-facing diagnostic
        counts[label, default: 0] += 1
        totals[label, default: 0] += 1

        let now = ContinuousClock.now
        let elapsed = lastEmit.duration(to: now)
        guard elapsed >= .seconds(1) else { return }
        lastEmit = now

        let seconds = max(
            0.001,
            Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1e18
        )
        let perSecond = counts
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\(Int(Double($0.value) / seconds))/s" }
            .joined(separator: " ")
        let busiest = counts.max { $0.value < $1.value }
        counts.removeAll(keepingCapacity: true)

        if let busiest, Double(busiest.value) / seconds > 100, !warned {
            warned = true
            PlozzLog.boot("BodyRate RUNAWAY driver=\(busiest.key) \(perSecond)")
        }
        PlozzLog.boot("BodyRate \(perSecond)")
    }
}
