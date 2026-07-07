import Foundation
import Observation

/// Live status of a media share's background scan + enrichment, per share. Drives
/// the "Updating library…" indicator on Home and the last-scanned line in Settings,
/// so the otherwise-invisible foreground scan is legible to the user.
public struct ShareScanState: Sendable, Equatable {
    /// Display name of the share (for the banner text).
    public var name: String
    /// A directory walk is in progress.
    public var isScanning: Bool
    /// Metadata/artwork enrichment is in progress (runs after the scan).
    public var isEnriching: Bool
    /// Items discovered so far in the current/last scan (for optional detail).
    public var itemsFound: Int
    /// When the last full scan completed (nil until the first completes).
    public var lastScanAt: Date?

    public init(name: String, isScanning: Bool = false, isEnriching: Bool = false,
                itemsFound: Int = 0, lastScanAt: Date? = nil) {
        self.name = name
        self.isScanning = isScanning
        self.isEnriching = isEnriching
        self.itemsFound = itemsFound
        self.lastScanAt = lastScanAt
    }

    /// Busy = actively scanning or enriching (the window the indicator shows).
    public var isBusy: Bool { isScanning || isEnriching }
}

/// App-level observable holding per-share scan status. The scanner (an actor in
/// `ProviderShare`) reports into it via a `Sendable` ``ShareScanReporter`` that
/// hops to the main actor; SwiftUI views observe this model directly.
@MainActor
@Observable
public final class ShareScanStatusModel {
    /// Keyed by the share's stable id (`server.id`).
    public private(set) var byShare: [String: ShareScanState] = [:]

    public init() {
        let (stream, continuation) = AsyncStream.makeStream(of: Event.self)
        self.continuation = continuation
        // A single main-actor pump applies events in stream order, so a late
        // `scanProgress` can never re-open a finished scan and no event is lost to
        // a scheduling reorder between the scanner's independent report tasks.
        self.pump = Task { [weak self] in
            for await event in stream { self?.apply(event) }
        }
    }

    deinit { continuation.finish() }

    /// Ordered delivery channel. The scanner/enricher run off-main and report from
    /// independent tasks; funnelling every event through one continuation → one
    /// pump makes application order deterministic and drop-free.
    @ObservationIgnored private nonisolated let continuation: AsyncStream<Event>.Continuation
    @ObservationIgnored private var pump: Task<Void, Never>?

    /// One reported scan/enrich event (see `reporter()`).
    enum Event: Sendable {
        case scanStarted(id: String, name: String)
        case scanProgress(id: String, items: Int)
        case scanFinished(id: String)
        case enrichStarted(id: String)
        case enrichFinished(id: String)
    }

    /// Apply one event, in stream order, on the main actor.
    private func apply(_ event: Event) {
        switch event {
        case let .scanStarted(id, name): scanStarted(shareID: id, name: name)
        case let .scanProgress(id, items): scanProgress(shareID: id, itemsFound: items)
        case let .scanFinished(id): scanFinished(shareID: id)
        case let .enrichStarted(id): enrichStarted(shareID: id)
        case let .enrichFinished(id): enrichFinished(shareID: id)
        }
    }

    /// Any share currently scanning or enriching.
    public var isAnyBusy: Bool { byShare.values.contains(where: { $0.isBusy }) }

    /// Display names of shares currently busy (for the banner text). Nameless
    /// states (a safety-net event applied before any named `scanStarted`) are
    /// skipped so the banner never shows a blank entry.
    public var busyShareNames: [String] {
        byShare.values.filter(\.isBusy).map(\.name).filter { !$0.isEmpty }.sorted()
    }

    public func state(forShareID shareID: String) -> ShareScanState? { byShare[shareID] }

    // MARK: - Mutations (called on the main actor via the reporter)

    public func scanStarted(shareID: String, name: String) {
        var state = byShare[shareID] ?? ShareScanState(name: name)
        state.name = name
        state.isScanning = true
        state.itemsFound = 0
        byShare[shareID] = state
    }

    public func scanProgress(shareID: String, itemsFound: Int) {
        guard var state = byShare[shareID] else { return }
        state.itemsFound = itemsFound
        byShare[shareID] = state
    }

    public func scanFinished(shareID: String) {
        guard var state = byShare[shareID] else { return }
        state.isScanning = false
        state.lastScanAt = Date()
        byShare[shareID] = state
    }

    public func enrichStarted(shareID: String) {
        guard var state = byShare[shareID] else { return }
        state.isEnriching = true
        byShare[shareID] = state
    }

    public func enrichFinished(shareID: String) {
        guard var state = byShare[shareID] else { return }
        state.isEnriching = false
        byShare[shareID] = state
    }

    /// A reporter that forwards scanner events onto this model **in order** via the
    /// serialized event stream (see `apply`). Held by the scanner/enricher (which
    /// run off-main), so passing it across the actor boundary is safe.
    public nonisolated func reporter() -> ShareScanReporter {
        let c = continuation
        return ShareScanReporter(
            scanStarted: { id, name in c.yield(.scanStarted(id: id, name: name)) },
            scanProgress: { id, count in c.yield(.scanProgress(id: id, items: count)) },
            scanFinished: { id in c.yield(.scanFinished(id: id)) },
            enrichStarted: { id in c.yield(.enrichStarted(id: id)) },
            enrichFinished: { id in c.yield(.enrichFinished(id: id)) }
        )
    }
}

/// A `Sendable` sink the off-main scanner/enricher report progress through. Kept
/// as plain closures so `ProviderShare` needn't know about the UI model; the
/// default is a no-op (tests / previews / no status model).
public struct ShareScanReporter: Sendable {
    public var scanStarted: @Sendable (_ shareID: String, _ name: String) -> Void
    public var scanProgress: @Sendable (_ shareID: String, _ itemsFound: Int) -> Void
    public var scanFinished: @Sendable (_ shareID: String) -> Void
    public var enrichStarted: @Sendable (_ shareID: String) -> Void
    public var enrichFinished: @Sendable (_ shareID: String) -> Void

    public init(
        scanStarted: @escaping @Sendable (String, String) -> Void,
        scanProgress: @escaping @Sendable (String, Int) -> Void,
        scanFinished: @escaping @Sendable (String) -> Void,
        enrichStarted: @escaping @Sendable (String) -> Void,
        enrichFinished: @escaping @Sendable (String) -> Void
    ) {
        self.scanStarted = scanStarted
        self.scanProgress = scanProgress
        self.scanFinished = scanFinished
        self.enrichStarted = enrichStarted
        self.enrichFinished = enrichFinished
    }

    /// No-op sink (default when no status model is wired).
    public static let noop = ShareScanReporter(
        scanStarted: { _, _ in }, scanProgress: { _, _ in }, scanFinished: { _ in },
        enrichStarted: { _ in }, enrichFinished: { _ in }
    )
}
