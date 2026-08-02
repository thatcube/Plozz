import Foundation
import Observation

/// Live status of a media share's background scan + enrichment, per share. Drives
/// the "Updating library…" indicator on Home and the last-scanned line in Settings,
/// so the otherwise-invisible foreground scan is legible to the user.
public struct ShareScanState: Sendable, Equatable, Identifiable {
    /// The media-share account id this state belongs to. Carried on the value (not
    /// just as the model's dictionary key) so a list of busy states is directly
    /// `ForEach`-able without the view having to re-thread ids alongside it.
    public var shareID: String
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
    /// Directories the walk still has queued (the BFS frontier: this level's
    /// undispatched tail plus the children discovered so far). Paired with
    /// ``directoriesScanned`` this makes the walk's progress a REAL fraction
    /// rather than an indeterminate spinner. 0 until a frontier-aware scanner
    /// reports one.
    public var directoriesPending: Int
    /// Highest walk fraction reached in the current pass. A breadth-first walk's
    /// denominator grows as it discovers subtrees, so the raw fraction can dip;
    /// holding the high-water mark keeps the bar from sliding backwards while the
    /// live item counter next to it keeps climbing. Reset on each `scanStarted`.
    public var scanFractionCeiling: Double
    /// Items enriched so far in the current enrichment pass.
    public var enrichDone: Int
    /// Total items in the current enrichment pass (0 until a pass advertises one).
    public var enrichTotal: Int
    /// When the last full scan completed (nil until the first completes).
    public var lastScanAt: Date?
    /// When a pass last actually changed the catalog — as opposed to merely
    /// finishing. This is what a UI should watch: a scan that found nothing has
    /// nothing to show.
    public var lastChangeAt: Date?

    public init(name: String, isScanning: Bool = false, isEnriching: Bool = false,
                itemsFound: Int = 0, directoriesScanned: Int = 0,
                directoriesPending: Int = 0, enrichDone: Int = 0, enrichTotal: Int = 0,
                lastScanAt: Date? = nil, shareID: String = "",
                scanFractionCeiling: Double = 0) {
        self.shareID = shareID
        self.name = name
        self.isScanning = isScanning
        self.isEnriching = isEnriching
        self.itemsFound = itemsFound
        self.directoriesScanned = directoriesScanned
        self.directoriesPending = directoriesPending
        self.enrichDone = enrichDone
        self.enrichTotal = enrichTotal
        self.lastScanAt = lastScanAt
        self.scanFractionCeiling = scanFractionCeiling
    }

    /// Stable identity for `ForEach`. Falls back to the display name for states
    /// built directly in previews/tests without an id.
    public var id: String { shareID.isEmpty ? name : shareID }

    /// Busy = actively scanning or enriching (the window the indicator shows).
    public var isBusy: Bool { isScanning || isEnriching }

    /// A short human label for the work in flight, or `nil` when idle.
    ///
    /// **One label, not one per pass.** The walk and the enrichment pass are not
    /// sequential: only a brand-new share runs them in order. A rescan of an
    /// established share starts while its enrichment backlog is still draining,
    /// so any "which phase is this" rule has to name one pass and stay silent
    /// about another that is genuinely running — the old rule said "Scanning"
    /// and hid enrichment entirely.
    ///
    /// The split was ours anyway. From outside there is one job (make the
    /// library current) and two questions: is it still working, and how far
    /// along. ``progressDetail`` and ``fraction`` answer the second; this
    /// answers the first, without claiming a stage boundary the user never
    /// asked about. It also stops the label under-selling the work — enrichment
    /// fetches cast, overview, genres, ratings and provider ids, not just the
    /// artwork the old copy named.
    public var phase: LocalizedStringResource? {
        guard isBusy else { return nil }
        return LocalizedStringResource(
            "shareScan.phase.updating",
            defaultValue: "Updating library",
            comment: "Status label shown while a media share is being scanned and/or having its metadata fetched. Deliberately covers both passes, which overlap."
        )
    }

    /// Which pass the numbers come from when both are running, or `nil` when
    /// there is nothing countable to report.
    ///
    /// Enrichment wins whenever it knows its denominator, because it is the only
    /// one of the two that can say how far along it is: a real "142 of 900" and
    /// a determinate bar. The walk can only offer a running tally and a
    /// self-correcting estimate. Under a single label the phase word no longer
    /// carries this decision, so it lives here — and it is the opposite of the
    /// old precedence, which showed the uncountable pass and suppressed the
    /// countable one.
    private var reportedPass: ReportedPass? {
        if isEnriching, enrichTotal > 0 { return .enriching }
        if isScanning { return .scanning }
        return nil
    }

    private enum ReportedPass { case scanning, enriching }

    /// The optional trailing progress detail (e.g. "1,234 items" during the walk,
    /// "142 of 900" while enriching), or `nil` when there's no count worth
    /// showing. Pure facts — the counts, plus the enrich pass's pre-padded `done`
    /// string (see `ScanProgressDetail`'s doc for the fixed-width constraint).
    /// The "folders"/"items"/"of" copy words live at the call site, composed as
    /// real `LocalizedStringResource`s, so they can be translated and the counts
    /// can carry plural catalog variations — see `ServerDetailView.busyStatusText`,
    /// `ShareScanStatusRow`, and `PlozziOSSettingsView`'s share section (all via
    /// the shared `CoreUI.scanProgressDetailText(_:)`).
    public var progressDetail: ScanProgressDetail? {
        switch reportedPass {
        case .scanning:
            if directoriesScanned > 0, itemsFound > 0 {
                return .foldersAndItems(folders: directoriesScanned, items: itemsFound)
            }
            if directoriesScanned > 0 { return .folders(directoriesScanned) }
            return itemsFound > 0 ? .items(itemsFound) : nil
        case .enriching:
            let totalStr = String(enrichTotal)
            let doneStr = String(min(enrichDone, enrichTotal))
            let pad = String(repeating: "\u{2007}", count: max(0, totalStr.count - doneStr.count))
            return .enriching(done: "\(pad)\(doneStr)", total: enrichTotal)
        case nil:
            return nil
        }
    }

    /// Enrichment completion in 0...1, or `nil` when no total is known (so the UI
    /// can fall back to an indeterminate spinner during the scan phase).
    public var enrichFraction: Double? {
        guard isEnriching, enrichTotal > 0 else { return nil }
        return min(1, Double(enrichDone) / Double(enrichTotal))
    }

    /// Real completion of the directory walk, from the breadth-first frontier:
    /// directories listed against directories listed + still queued. Genuine
    /// progress (not a guess from a previous scan), self-correcting as the walk
    /// discovers subtrees, and monotonic via ``scanFractionCeiling`` so it never
    /// slides backwards. Capped just below 1 so it can't read "100%" while the
    /// walk is still going; `nil` before the first frontier report.
    public var scanFraction: Double? {
        guard isScanning else { return nil }
        let known = directoriesScanned + directoriesPending
        guard known > 0, directoriesScanned > 0 else { return nil }
        let raw = Double(directoriesScanned) / Double(known)
        return min(0.99, max(raw, scanFractionCeiling))
    }

    /// The single 0...1 completion a progress bar should draw — from the same
    /// pass ``progressDetail`` reports, so the bar and the numbers under it can
    /// never describe different work. `nil` when neither pass has a usable
    /// measure yet, which the bar renders as its indeterminate sweep.
    public var fraction: Double? {
        switch reportedPass {
        case .scanning: return scanFraction
        case .enriching: return enrichFraction
        case nil: return nil
        }
    }
}

/// Facts behind `ShareScanState.progressDetail` — no copy words, so this stays a
/// plain CoreModels type. The view composes the actual sentence (see
/// `CoreUI.scanProgressDetailText(_:)`), since the "folders"/"items"/"of"
/// wording needs to be real, pluralizable `LocalizedStringResource`s.
public enum ScanProgressDetail: Equatable, Sendable {
    case foldersAndItems(folders: Int, items: Int)
    case folders(Int)
    case items(Int)
    /// `done` arrives pre-padded: left-padded with figure spaces (which share
    /// `monospacedDigit`'s tabular width) to the width of `total`, and neither
    /// side carries a grouping separator. That keeps the "N of M" string a
    /// **fixed width** for the whole enrichment pass, so the pill can't jitter
    /// as the counter climbs — a comma is NOT tabular under `monospacedDigit`,
    /// so "999 of 1,000" and "1,000 of 1,000" would differ in width right at
    /// the thousands boundary. `total` stays a plain `Int` (not pre-formatted)
    /// so it remains a real, pluralizable catalog substitution; the caller
    /// must render it with grouping disabled (e.g. `.formatted(.number
    /// .grouping(.never))`) to preserve `done`'s matching, ungrouped width.
    case enriching(done: String, total: Int)
}

/// App-level observable holding per-share scan status. The scanner (an actor in
/// `ProviderShare`) reports into it via a `Sendable` ``ShareScanReporter`` that
/// hops to the main actor; SwiftUI views observe this model directly.
@MainActor
@Observable
public final class ShareScanStatusModel {
    public typealias ProgressSleep = @Sendable (Duration) async throws -> Void

    /// Keyed by the media-share account id used by the catalog coordinator.
    public private(set) var byShare: [String: ShareScanState] = [:]
    /// Test/diagnostic counter for actual observable state publications.
    @ObservationIgnored public private(set) var statePublicationCount = 0

    public init(
        progressPublicationInterval: Duration = .milliseconds(250),
        progressSleep: @escaping ProgressSleep = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        let (stream, continuation) = AsyncStream.makeStream(of: Event.self)
        inbox = EventInbox(
            continuation: continuation,
            interval: progressPublicationInterval,
            sleep: progressSleep
        )
        // A single main-actor pump applies events in stream order, so a late
        // `scanProgress` can never re-open a finished scan and no event is lost to
        // a scheduling reorder between the scanner's independent report tasks.
        self.pump = Task { [weak self] in
            for await event in stream { self?.apply(event) }
        }
    }

    deinit { inbox.finish() }

    /// Progress is latest-value coalesced before it reaches the ordered lifecycle
    /// stream. This bounds producer bursts without ever dropping start/finish events.
    @ObservationIgnored private nonisolated let inbox: EventInbox
    @ObservationIgnored private var pump: Task<Void, Never>?
    /// Removed account ids are fenced so scanner events already queued during
    /// cancellation cannot recreate a stale Home banner.
    @ObservationIgnored private var removedShareIDs: Set<String> = []

    /// One reported scan/enrich event (see `reporter()`).
    enum Event: Sendable {
        case shareRegistered(id: String)
        case scanStarted(id: String, name: String)
        case scanProgress(id: String, directories: Int, pending: Int, items: Int)
        case scanFinished(id: String)
        case scanChangedCatalog(id: String)
        case enrichStarted(id: String, total: Int)
        case enrichProgress(id: String, done: Int)
        case enrichFinished(id: String)
        case shareRemoved(id: String)
    }

    private final class EventInbox: @unchecked Sendable {
        private enum ProgressKey: Hashable {
            case scan(String)
            case enrich(String)
        }

        private let lock = NSLock()
        private let continuation: AsyncStream<Event>.Continuation
        private let interval: Duration
        private let sleep: ProgressSleep
        private var pendingProgress: [ProgressKey: Event] = [:]
        private var flushTask: Task<Void, Never>?
        private var isFinished = false

        init(
            continuation: AsyncStream<Event>.Continuation,
            interval: Duration,
            sleep: @escaping ProgressSleep
        ) {
            self.continuation = continuation
            self.interval = interval
            self.sleep = sleep
        }

        func submitLifecycle(_ event: Event) {
            let pending = takePendingProgress(cancelScheduledFlush: true)
            for event in pending {
                continuation.yield(event)
            }
            continuation.yield(event)
        }

        func submitProgress(_ event: Event) {
            let key: ProgressKey
            switch event {
            case let .scanProgress(id, _, _, _):
                key = .scan(id)
            case let .enrichProgress(id, _):
                key = .enrich(id)
            default:
                submitLifecycle(event)
                return
            }

            lock.lock()
            guard !isFinished else {
                lock.unlock()
                return
            }
            pendingProgress[key] = event
            guard flushTask == nil else {
                lock.unlock()
                return
            }
            let interval = interval
            let sleep = sleep
            flushTask = Task { [weak self] in
                do {
                    try await sleep(interval)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self?.flushProgress()
            }
            lock.unlock()
        }

        func finish() {
            let pending = takePendingProgress(
                cancelScheduledFlush: true,
                markFinished: true
            )
            for event in pending {
                continuation.yield(event)
            }
            continuation.finish()
        }

        private func flushProgress() {
            let pending = takePendingProgress(cancelScheduledFlush: false)
            for event in pending {
                continuation.yield(event)
            }
        }

        private func takePendingProgress(
            cancelScheduledFlush: Bool,
            markFinished: Bool = false
        ) -> [Event] {
            lock.lock()
            if markFinished {
                isFinished = true
            }
            if cancelScheduledFlush {
                flushTask?.cancel()
            }
            flushTask = nil
            let events = pendingProgress
                .sorted { String(describing: $0.key) < String(describing: $1.key) }
                .map(\.value)
            pendingProgress.removeAll(keepingCapacity: true)
            lock.unlock()
            return events
        }
    }

    /// Apply one event, in stream order, on the main actor.
    private func apply(_ event: Event) {
        switch event {
        case let .shareRegistered(id): registerShare(shareID: id)
        case let .scanStarted(id, name): scanStarted(shareID: id, name: name)
        case let .scanProgress(id, directories, pending, items):
            scanProgress(
                shareID: id,
                directoriesScanned: directories,
                directoriesPending: pending,
                itemsFound: items
            )
        case let .scanFinished(id): scanFinished(shareID: id)
        case let .scanChangedCatalog(id): catalogChanged(shareID: id)
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

    /// Busy states limited to a profile's active media-share account ids.
    public func busyStates(forShareIDs shareIDs: Set<String>) -> [ShareScanState] {
        byShare
            .filter { shareIDs.contains($0.key) && $0.value.isBusy }
            .map(\.value)
            .sorted { $0.name < $1.name }
    }

    public func state(forShareID shareID: String) -> ShareScanState? { byShare[shareID] }

    /// Whether a share with this display name is currently busy — lets a per-share
    /// library card show its own updating indicator without knowing the share's id.
    public func isBusy(shareNamed name: String) -> Bool {
        guard !name.isEmpty else { return false }
        return byShare.values.contains { $0.isBusy && $0.name == name }
    }

    // MARK: - Mutations (called on the main actor via the reporter)

    /// Opens a fresh lifecycle for a deterministic share id after coordinator
    /// invalidation has fully drained the removed instance.
    public func registerShare(shareID: String) {
        removedShareIDs.remove(shareID)
    }

    public func scanStarted(shareID: String, name: String) {
        guard !removedShareIDs.contains(shareID) else { return }
        var state = byShare[shareID] ?? ShareScanState(name: name, shareID: shareID)
        state.shareID = shareID
        state.name = name
        state.isScanning = true
        state.itemsFound = 0
        state.directoriesScanned = 0
        state.directoriesPending = 0
        state.scanFractionCeiling = 0
        publish(state, for: shareID)
    }

    public func scanProgress(
        shareID: String,
        directoriesScanned: Int,
        directoriesPending: Int,
        itemsFound: Int
    ) {
        guard var state = byShare[shareID], state.isScanning else { return }
        state.directoriesScanned = directoriesScanned
        state.directoriesPending = directoriesPending
        state.itemsFound = itemsFound
        // Latch the high-water mark BEFORE the view reads `scanFraction`, so the
        // bar only ever moves forward within a pass.
        if let fraction = state.scanFraction {
            state.scanFractionCeiling = fraction
        }
        publish(state, for: shareID)
    }

    /// Source compatibility for callers that have no frontier count.
    public func scanProgress(shareID: String, directoriesScanned: Int, itemsFound: Int) {
        scanProgress(
            shareID: shareID,
            directoriesScanned: directoriesScanned,
            directoriesPending: byShare[shareID]?.directoriesPending ?? 0,
            itemsFound: itemsFound
        )
    }

    /// Source compatibility for direct model callers that only care about items.
    public func scanProgress(shareID: String, itemsFound: Int) {
        scanProgress(
            shareID: shareID,
            directoriesScanned: byShare[shareID]?.directoriesScanned ?? 0,
            directoriesPending: byShare[shareID]?.directoriesPending ?? 0,
            itemsFound: itemsFound
        )
    }

    /// Record that a completed pass actually altered the catalog.
    ///
    /// Distinct from `lastScanAt` on purpose: a scan finishing is not news, and
    /// treating it as news made Home reload on every poll. Only a pass that added
    /// or removed something can change what is on screen, so only that should
    /// cause a refresh.
    public func catalogChanged(shareID: String) {
        guard var state = byShare[shareID] else { return }
        state.lastChangeAt = Date()
        publish(state, for: shareID)
    }

    public func scanFinished(shareID: String) {
        guard var state = byShare[shareID] else { return }
        state.isScanning = false
        state.directoriesPending = 0
        state.scanFractionCeiling = 0
        state.lastScanAt = Date()
        publish(state, for: shareID)
    }

    public func enrichStarted(shareID: String, total: Int) {
        guard !removedShareIDs.contains(shareID) else { return }
        // Create state if the enrich pass beat a (missed) scanStarted — the banner
        // should still reflect in-flight enrichment.
        var state = byShare[shareID] ?? ShareScanState(name: "", shareID: shareID)
        state.shareID = shareID
        state.isEnriching = true
        state.enrichTotal = total
        state.enrichDone = 0
        publish(state, for: shareID)
    }

    public func enrichProgress(shareID: String, done: Int) {
        guard var state = byShare[shareID], state.isEnriching else { return }
        state.enrichDone = done
        publish(state, for: shareID)
    }

    public func enrichFinished(shareID: String) {
        guard var state = byShare[shareID] else { return }
        state.isEnriching = false
        state.enrichDone = 0
        state.enrichTotal = 0
        publish(state, for: shareID)
    }

    /// Immediately removes a deleted share from every status surface and fences
    /// progress already queued by its cancelling scanner.
    public func removeShare(shareID: String) {
        removedShareIDs.insert(shareID)
        publish(nil, for: shareID)
    }

    private func publish(_ state: ShareScanState?, for shareID: String) {
        guard byShare[shareID] != state else { return }
        byShare[shareID] = state
        statePublicationCount += 1
    }

    /// A reporter that forwards scanner events onto this model **in order** via the
    /// serialized event stream (see `apply`). Held by the scanner/enricher (which
    /// run off-main), so passing it across the actor boundary is safe.
    public nonisolated func reporter() -> ShareScanReporter {
        let inbox = inbox
        return ShareScanReporter(
            shareRegistered: { id in
                inbox.submitLifecycle(.shareRegistered(id: id))
            },
            scanStarted: { id, name in
                inbox.submitLifecycle(.scanStarted(id: id, name: name))
            },
            scanProgress: { id, items in
                inbox.submitProgress(
                    .scanProgress(
                        id: id,
                        directories: 0,
                        pending: 0,
                        items: items
                    )
                )
            },
            scanDetailedProgress: { id, directories, items in
                inbox.submitProgress(
                    .scanProgress(
                        id: id,
                        directories: directories,
                        pending: 0,
                        items: items
                    )
                )
            },
            scanFrontierProgress: { id, directories, pending, items in
                inbox.submitProgress(
                    .scanProgress(
                        id: id,
                        directories: directories,
                        pending: pending,
                        items: items
                    )
                )
            },
            scanFinished: { id in
                inbox.submitLifecycle(.scanFinished(id: id))
            },
            scanChangedCatalog: { id in
                inbox.submitLifecycle(.scanChangedCatalog(id: id))
            },
            enrichStarted: { id, total in
                inbox.submitLifecycle(.enrichStarted(id: id, total: total))
            },
            enrichProgress: { id, done in
                inbox.submitProgress(.enrichProgress(id: id, done: done))
            },
            enrichFinished: { id in
                inbox.submitLifecycle(.enrichFinished(id: id))
            },
            shareRemoved: { id in
                inbox.submitLifecycle(.shareRemoved(id: id))
            },
        )
    }
}

/// A `Sendable` sink the off-main scanner/enricher report progress through. Kept
/// as plain closures so `ProviderShare` needn't know about the UI model; the
/// default is a no-op (tests / previews / no status model).
public struct ShareScanReporter: Sendable {
    public var shareRegistered: @Sendable (_ shareID: String) -> Void
    public var scanStarted: @Sendable (_ shareID: String, _ name: String) -> Void
    /// Source-compatible item-only progress callback.
    public var scanProgress: @Sendable (_ shareID: String, _ itemsFound: Int) -> Void
    /// Additive detailed progress for directory-aware scanners.
    public var scanDetailedProgress: @Sendable (_ shareID: String, _ directoriesScanned: Int, _ itemsFound: Int) -> Void
    /// Additive progress for frontier-aware (breadth-first) scanners, which also
    /// know how many directories are still QUEUED. That pending count is what
    /// turns the walk into a real progress fraction instead of a spinner.
    public var scanFrontierProgress: @Sendable (
        _ shareID: String,
        _ directoriesScanned: Int,
        _ directoriesPending: Int,
        _ itemsFound: Int
    ) -> Void
    public var scanFinished: @Sendable (_ shareID: String) -> Void
    /// Called only when a completed pass actually changed the catalog.
    public var scanChangedCatalog: @Sendable (_ shareID: String) -> Void
    public var enrichStarted: @Sendable (_ shareID: String, _ total: Int) -> Void
    public var enrichProgress: @Sendable (_ shareID: String, _ done: Int) -> Void
    public var enrichFinished: @Sendable (_ shareID: String) -> Void
    public var shareRemoved: @Sendable (_ shareID: String) -> Void

    public init(
        shareRegistered: @escaping @Sendable (String) -> Void = { _ in },
        scanStarted: @escaping @Sendable (String, String) -> Void,
        scanProgress: @escaping @Sendable (String, Int) -> Void,
        scanDetailedProgress: (@Sendable (String, Int, Int) -> Void)? = nil,
        scanFrontierProgress: (@Sendable (String, Int, Int, Int) -> Void)? = nil,
        scanFinished: @escaping @Sendable (String) -> Void,
        // Optional so every existing reporter (tests, fakes) keeps compiling and
        // simply never reports a change.
        scanChangedCatalog: (@Sendable (String) -> Void)? = nil,
        enrichStarted: @escaping @Sendable (String, Int) -> Void,
        enrichProgress: @escaping @Sendable (String, Int) -> Void,
        enrichFinished: @escaping @Sendable (String) -> Void,
        shareRemoved: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.shareRegistered = shareRegistered
        self.scanStarted = scanStarted
        self.scanProgress = scanProgress
        self.scanChangedCatalog = scanChangedCatalog ?? { _ in }
        let resolvedDetailed = scanDetailedProgress ?? { id, _, items in
            scanProgress(id, items)
        }
        self.scanDetailedProgress = resolvedDetailed
        self.scanFrontierProgress = scanFrontierProgress ?? { id, directories, _, items in
            resolvedDetailed(id, directories, items)
        }
        self.scanFinished = scanFinished
        self.enrichStarted = enrichStarted
        self.enrichProgress = enrichProgress
        self.enrichFinished = enrichFinished
        self.shareRemoved = shareRemoved
    }

    /// No-op sink (default when no status model is wired).
    public static let noop = ShareScanReporter(
        shareRegistered: { _ in },
        scanStarted: { _, _ in }, scanProgress: { _, _ in },
        scanDetailedProgress: { _, _, _ in },
        scanFrontierProgress: { _, _, _, _ in },
        scanFinished: { _ in },
        enrichStarted: { _, _ in }, enrichProgress: { _, _ in },
        enrichFinished: { _ in }, shareRemoved: { _ in }
    )
}
