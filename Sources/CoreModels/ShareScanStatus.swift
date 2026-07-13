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
    /// Directories listed so far. This advances even through folders with no media,
    /// so a slow walk never looks frozen merely because the item count is unchanged.
    public var directoriesScanned: Int
    /// Items enriched so far in the current enrichment pass.
    public var enrichDone: Int
    /// Total items in the current enrichment pass (0 until a pass advertises one).
    public var enrichTotal: Int
    /// When the last full scan completed (nil until the first completes).
    public var lastScanAt: Date?

    public init(name: String, isScanning: Bool = false, isEnriching: Bool = false,
                itemsFound: Int = 0, directoriesScanned: Int = 0,
                enrichDone: Int = 0, enrichTotal: Int = 0,
                lastScanAt: Date? = nil) {
        self.name = name
        self.isScanning = isScanning
        self.isEnriching = isEnriching
        self.itemsFound = itemsFound
        self.directoriesScanned = directoriesScanned
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
    /// During enrichment the `done`/`total` counters are rendered WITHOUT grouping
    /// separators and `done` is left-padded (with figure spaces, which share the
    /// tabular-digit width) to the width of `total` — so, paired with a
    /// monospaced-digit font, the string is a **fixed width** for the whole pass and
    /// the pill can't jitter as the counter flies. (Grouping commas are deliberately
    /// dropped here: a comma is NOT tabular under `monospacedDigit`, so "999 of 1,000"
    /// and "1,000 of 1,000" would differ in width at the thousands boundary.)
    public var progressDetail: String? {
        if isScanning {
            if directoriesScanned > 0, itemsFound > 0 {
                return "\(Self.decimal(directoriesScanned)) folders · \(Self.decimal(itemsFound)) items"
            }
            if directoriesScanned > 0 { return "\(Self.decimal(directoriesScanned)) folders" }
            return itemsFound > 0 ? "\(Self.decimal(itemsFound)) items" : nil
        }
        if isEnriching, enrichTotal > 0 {
            let totalStr = String(enrichTotal)
            let doneStr = String(min(enrichDone, enrichTotal))
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
    /// Keyed by the media-share account id used by the catalog coordinator.
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
    /// Removed account ids are fenced so scanner events already queued during
    /// cancellation cannot recreate a stale Home banner.
    @ObservationIgnored private var removedShareIDs: Set<String> = []

    /// One reported scan/enrich event (see `reporter()`).
    enum Event: Sendable {
        case scanStarted(id: String, name: String)
        case scanProgress(id: String, directories: Int, items: Int)
        case scanFinished(id: String)
        case enrichStarted(id: String, total: Int)
        case enrichProgress(id: String, done: Int)
        case enrichFinished(id: String)
        case shareRemoved(id: String)
    }

    /// Apply one event, in stream order, on the main actor.
    private func apply(_ event: Event) {
        switch event {
        case let .scanStarted(id, name): scanStarted(shareID: id, name: name)
        case let .scanProgress(id, directories, items):
            scanProgress(shareID: id, directoriesScanned: directories, itemsFound: items)
        case let .scanFinished(id): scanFinished(shareID: id)
        case let .enrichStarted(id, total): enrichStarted(shareID: id, total: total)
        case let .enrichProgress(id, done): enrichProgress(shareID: id, done: done)
        case let .enrichFinished(id): enrichFinished(shareID: id)
        case let .shareRemoved(id): removeShare(shareID: id)
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
        guard !removedShareIDs.contains(shareID) else { return }
        var state = byShare[shareID] ?? ShareScanState(name: name)
        state.name = name
        state.isScanning = true
        state.itemsFound = 0
        state.directoriesScanned = 0
        byShare[shareID] = state
    }

    public func scanProgress(shareID: String, directoriesScanned: Int, itemsFound: Int) {
        guard var state = byShare[shareID] else { return }
        state.directoriesScanned = directoriesScanned
        state.itemsFound = itemsFound
        byShare[shareID] = state
    }

    /// Source compatibility for direct model callers that only care about items.
    public func scanProgress(shareID: String, itemsFound: Int) {
        scanProgress(
            shareID: shareID,
            directoriesScanned: byShare[shareID]?.directoriesScanned ?? 0,
            itemsFound: itemsFound
        )
    }

    public func scanFinished(shareID: String) {
        guard var state = byShare[shareID] else { return }
        state.isScanning = false
        state.lastScanAt = Date()
        byShare[shareID] = state
    }

    public func enrichStarted(shareID: String, total: Int) {
        guard !removedShareIDs.contains(shareID) else { return }
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

    /// Immediately removes a deleted share from every status surface and fences
    /// progress already queued by its cancelling scanner.
    public func removeShare(shareID: String) {
        removedShareIDs.insert(shareID)
        byShare[shareID] = nil
    }

    /// A reporter that forwards scanner events onto this model **in order** via the
    /// serialized event stream (see `apply`). Held by the scanner/enricher (which
    /// run off-main), so passing it across the actor boundary is safe.
    public nonisolated func reporter() -> ShareScanReporter {
        let c = continuation
        return ShareScanReporter(
            scanStarted: { id, name in c.yield(.scanStarted(id: id, name: name)) },
            scanProgress: { id, items in
                c.yield(.scanProgress(id: id, directories: 0, items: items))
            },
            scanDetailedProgress: { id, directories, items in
                c.yield(.scanProgress(id: id, directories: directories, items: items))
            },
            scanFinished: { id in c.yield(.scanFinished(id: id)) },
            enrichStarted: { id, total in c.yield(.enrichStarted(id: id, total: total)) },
            enrichProgress: { id, done in c.yield(.enrichProgress(id: id, done: done)) },
            enrichFinished: { id in c.yield(.enrichFinished(id: id)) },
            shareRemoved: { id in c.yield(.shareRemoved(id: id)) }
        )
    }
}

/// A `Sendable` sink the off-main scanner/enricher report progress through. Kept
/// as plain closures so `ProviderShare` needn't know about the UI model; the
/// default is a no-op (tests / previews / no status model).
public struct ShareScanReporter: Sendable {
    public var scanStarted: @Sendable (_ shareID: String, _ name: String) -> Void
    /// Source-compatible item-only progress callback.
    public var scanProgress: @Sendable (_ shareID: String, _ itemsFound: Int) -> Void
    /// Additive detailed progress for directory-aware scanners.
    public var scanDetailedProgress: @Sendable (_ shareID: String, _ directoriesScanned: Int, _ itemsFound: Int) -> Void
    public var scanFinished: @Sendable (_ shareID: String) -> Void
    public var enrichStarted: @Sendable (_ shareID: String, _ total: Int) -> Void
    public var enrichProgress: @Sendable (_ shareID: String, _ done: Int) -> Void
    public var enrichFinished: @Sendable (_ shareID: String) -> Void
    public var shareRemoved: @Sendable (_ shareID: String) -> Void

    public init(
        scanStarted: @escaping @Sendable (String, String) -> Void,
        scanProgress: @escaping @Sendable (String, Int) -> Void,
        scanDetailedProgress: (@Sendable (String, Int, Int) -> Void)? = nil,
        scanFinished: @escaping @Sendable (String) -> Void,
        enrichStarted: @escaping @Sendable (String, Int) -> Void,
        enrichProgress: @escaping @Sendable (String, Int) -> Void,
        enrichFinished: @escaping @Sendable (String) -> Void,
        shareRemoved: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.scanStarted = scanStarted
        self.scanProgress = scanProgress
        self.scanDetailedProgress = scanDetailedProgress ?? { id, _, items in
            scanProgress(id, items)
        }
        self.scanFinished = scanFinished
        self.enrichStarted = enrichStarted
        self.enrichProgress = enrichProgress
        self.enrichFinished = enrichFinished
        self.shareRemoved = shareRemoved
    }

    /// No-op sink (default when no status model is wired).
    public static let noop = ShareScanReporter(
        scanStarted: { _, _ in }, scanProgress: { _, _ in },
        scanDetailedProgress: { _, _, _ in }, scanFinished: { _ in },
        enrichStarted: { _, _ in }, enrichProgress: { _, _ in },
        enrichFinished: { _ in }, shareRemoved: { _ in }
    )
}
