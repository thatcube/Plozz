#if canImport(SwiftUI)
import CoreNetworking
import Foundation
import SwiftUI

/// A pass-through `Layout` that times how long its subtree spends being
/// **measured and placed**, so an expensive screen can be attributed to a
/// section instead of guessed at.
///
/// SwiftUI layout is where this app's hangs actually live: the fatal-hang stack
/// Sentry captured was 100 frames of `StackLayout.sizeThatFits` /
/// `explicitAlignment` recursion with no app frame in it at all. That tells you
/// layout is the cost but never *which* view — and `_printChanges()` cannot
/// help, because a single body pass can be followed by an arbitrarily expensive
/// layout pass over the tree it produced.
///
/// Wrapping a section in ``timedLayout(_:)`` reports the real number:
///
/// ```
/// PLZLAYOUT hero=412ms/38 episodes=1180ms/38 cast=61ms/38
/// ```
///
/// (total milliseconds and the number of measure passes since the last report —
/// a large pass *count* is its own finding, since a section being measured
/// dozens of times per frame is a different bug from one that is simply slow.)
///
/// Inert unless launched with `PLZSTALL=1`; the modifier then returns the
/// content unchanged, so shipping builds keep the exact view tree they had.
public struct TimedLayout: Layout {
    private let name: String

    public init(_ name: String) { self.name = name }

    public func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let start = DispatchTime.now().uptimeNanoseconds
        // Faithful pass-through: one child, offered exactly what we were
        // offered, so wrapping a section cannot change how it sizes.
        let size = subviews.first?.sizeThatFits(proposal) ?? .zero
        LayoutTimings.shared.record(
            name, nanos: DispatchTime.now().uptimeNanoseconds &- start
        )
        return size
    }

    public func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let start = DispatchTime.now().uptimeNanoseconds
        for subview in subviews {
            subview.place(at: bounds.origin, proposal: proposal)
        }
        LayoutTimings.shared.record(
            name, nanos: DispatchTime.now().uptimeNanoseconds &- start
        )
    }
}

/// Accumulates ``TimedLayout`` samples and prints one line per second, so the
/// stream stays readable while a screen is being exercised.
public final class LayoutTimings: @unchecked Sendable {
    public static let shared = LayoutTimings()

    private let lock = NSLock()
    private var totals: [String: UInt64] = [:]
    private var counts: [String: Int] = [:]
    private var lastEmit = DispatchTime.now().uptimeNanoseconds

    private init() {}

    func record(_ name: String, nanos: UInt64) {
        lock.lock()
        totals[name, default: 0] &+= nanos
        counts[name, default: 0] += 1
        let now = DispatchTime.now().uptimeNanoseconds
        guard now &- lastEmit >= 1_000_000_000, !totals.isEmpty else {
            lock.unlock()
            return
        }
        let snapshot = totals.map { key, value in
            "\(key)=\(value / 1_000_000)ms/\(counts[key] ?? 0)"
        }
        .sorted()
        totals.removeAll(keepingCapacity: true)
        counts.removeAll(keepingCapacity: true)
        lastEmit = now
        lock.unlock()
        PlozzLog.boot("PLZLAYOUT " + snapshot.joined(separator: " "))
    }
}

public extension View {
    /// Times this subtree's layout under `name`. Returns `self` unchanged unless
    /// the diagnostic build flag is set, so it is safe to leave at call sites.
    @ViewBuilder
    func timedLayout(_ name: String) -> some View {
        if MainThreadStallProbe.printsChanges {
            TimedLayout(name) { self }
        } else {
            self
        }
    }
}
#endif
