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
    /// Items enriched so far in the current enrichment pass.
    public var enrichDone: Int
    /// Total items in the current enrichment pass (0 until a pass advertises one).
    public var enrichTotal: Int
    /// When the last full scan completed (nil until the first completes).
    public var lastScanAt: Date?

    public init(name: String, isScanning: Bool = false, isEnriching: Bool = false,
                itemsFound: Int = 0, enrichDone: Int = 0, enrichTotal: Int = 0,
                lastScanAt: Date? = nil) {
        self.name = name
        self.isScanning = isScanning
        self.isEnriching = isEnriching
        self.itemsFound = itemsFound
        self.enrichDone = enrichDone
        self.enrichTotal = enrichTotal
        self.lastScanAt = lastScanAt
    }

    /// Busy = actively scanning or enriching (the window the indicator shows).
    public var isBusy: Bool { isScanning || isEnriching }

    /// A short human phase label — what the share is doing right now. Scanning wins
    /// over enriching when (briefly) both are true, since the walk is the earlier,
    /// more fundamental stage.
    public var phase: String {
        if isScanning { return "Scanning" }
        if isEnriching { return "Updating artwork" }
        return ""
    }

    /// The optional trailing progress detail (e.g. "1,234 items" while scanning,
    /// "142 of 900" while enriching), or `nil` when there's no count worth showing.
    /// During enrichment the `done` value is left-padded (with figure spaces, which
    /// share the tabular-digit width) to the width of `total`, so — paired with a
    /// monospaced-digit font — the string stays a **fixed width** for the whole
    /// pass and the pill never jitters as the counter flies up.
    public var progressDetail: String? {
        if isScanning {
            return itemsFound > 0 ? "\(Self.decimal(itemsFound)) items" : nil
        }
        if isEnriching, enrichTotal > 0 {
            let totalStr = Self.decimal(enrichTotal)
            let doneStr = Self.decimal(min(enrichDone, enrichTotal))
            let pad = String(repeating: "\u{2007}", count: max(0, totalStr.count - doneStr.count))
            return "\(pad)\(doneStr) of \(totalStr)"
        }
        return nil
    }

    /// Enrichment completion in 0...1, or `nil` when no total is known (so the UI
    /// can fall back to an indeterminate spinner during the scan phase).
    public var enrichFraction: Double? {
        guard isEnriching, enrichTotal > 0 else { return nil }
        return min(1, Double(enrichDone) / Double(enrichTotal))
    }

    private static func decimal(_ n: Int) -> String {
        Self.decimalFormatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }
    private static let decimalFormatter: NumberFormatter = {
        let f = NumberFormatter(); f.numberStyle = .decimal; return f
    }()
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
        case enrichStarted(id: String, total: Int)
        case enrichProgress(id: String, done: Int)
        case enrichFinished(id: String)
    }

    /// Apply one event, in stream order, on the main actor.
    private func apply(_ event: Event) {
        switch event {
        case let .scanStarted(id, name): scanStarted(shareID: id, name: name)
        case let .scanProgress(id, items): scanProgress(shareID: id, itemsFound: items)
        case let .scanFinished(id): scanFinished(shareID: id)
        case let .enrichStarted(id, total): enrichStarted(shareID: id, total: total)
        case let .enrichProgress(id, done): enrichProgress(shareID: id, done: done)
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

    /// Busy shares' full states (name + phase + progress), ordered by name — drives
    /// the rich Home status pill.
    public var busyStates: [ShareScanState] {
        byShare.values.filter(\.isBusy).sorted { $0.name < $1.name }
    }

    public func state(forShareID shareID: String) -> ShareScanState? { byShare[shareID] }

    /// Whether a share with this display name is currently busy — lets a per-share
    /// library card show its own updating indicator without knowing the share's id.
    public func isBusy(shareNamed name: String) -> Bool {
        guard !name.isEmpty else { return false }
        return byShare.values.contains { $0.isBusy && $0.name == name }
    }

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

    public func enrichStarted(shareID: String, total: Int) {
        // Create state if the enrich pass beat a (missed) scanStarted — the banner
        // should still reflect in-flight enrichment.
        var state = byShare[shareID] ?? ShareScanState(name: "")
        state.isEnriching = true
        state.enrichTotal = total
        state.enrichDone = 0
        byShare[shareID] = state
    }

    public func enrichProgress(shareID: String, done: Int) {
        guard var state = byShare[shareID] else { return }
        state.enrichDone = done
        byShare[shareID] = state
    }

    public func enrichFinished(shareID: String) {
        guard var state = byShare[shareID] else { return }
        state.isEnriching = false
        state.enrichDone = 0
        state.enrichTotal = 0
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
            enrichStarted: { id, total in c.yield(.enrichStarted(id: id, total: total)) },
            enrichProgress: { id, done in c.yield(.enrichProgress(id: id, done: done)) },
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
    public var enrichStarted: @Sendable (_ shareID: String, _ total: Int) -> Void
    public var enrichProgress: @Sendable (_ shareID: String, _ done: Int) -> Void
    public var enrichFinished: @Sendable (_ shareID: String) -> Void

    public init(
        scanStarted: @escaping @Sendable (String, String) -> Void,
        scanProgress: @escaping @Sendable (String, Int) -> Void,
        scanFinished: @escaping @Sendable (String) -> Void,
        enrichStarted: @escaping @Sendable (String, Int) -> Void,
        enrichProgress: @escaping @Sendable (String, Int) -> Void,
        enrichFinished: @escaping @Sendable (String) -> Void
    ) {
        self.scanStarted = scanStarted
        self.scanProgress = scanProgress
        self.scanFinished = scanFinished
        self.enrichStarted = enrichStarted
        self.enrichProgress = enrichProgress
        self.enrichFinished = enrichFinished
    }

    /// No-op sink (default when no status model is wired).
    public static let noop = ShareScanReporter(
        scanStarted: { _, _ in }, scanProgress: { _, _ in }, scanFinished: { _ in },
        enrichStarted: { _, _ in }, enrichProgress: { _, _ in }, enrichFinished: { _ in }
    )
}
