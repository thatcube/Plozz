import Foundation

/// Process-wide memo of trailer resolution outcomes, keyed by library item id.
///
/// Resolving a playable trailer is expensive (YouTube extraction + a byte-reach
/// check, and sometimes a keyless search). Without a cache, every visit to a
/// detail page — and every re-focus that reloads it — pays that cost again, which
/// is the main reason the Trailer button used to take 5–10s to appear. Caching
/// the *outcome* makes a revisited page resolve its button instantly, and lets a
/// background verification done once stick for the session.
///
/// Only the keyless-trailer *decision* is cached (a working YouTube id, or "no
/// playable trailer"); local server trailers aren't cached because they're cheap
/// (no network) and provider-owned. Thread-safe so a background verification task
/// can record into it.
public final class TrailerResolutionCache: @unchecked Sendable {
    public enum Outcome: Equatable {
        /// A YouTube video id verified (or optimistically chosen) as the trailer.
        case working(String)
        /// No playable trailer exists for this item — hide the button.
        case none
    }

    public static let shared = TrailerResolutionCache()

    private let lock = NSLock()
    private var store: [String: Outcome] = [:]

    public init() {}

    public func outcome(for itemID: String) -> Outcome? {
        lock.lock(); defer { lock.unlock() }
        return store[itemID]
    }

    public func record(_ outcome: Outcome, for itemID: String) {
        lock.lock(); defer { lock.unlock() }
        store[itemID] = outcome
    }

    /// Drops a cached outcome (used by tests to isolate cases).
    public func reset(_ itemID: String) {
        lock.lock(); defer { lock.unlock() }
        store[itemID] = nil
    }
}
