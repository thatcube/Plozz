import Foundation

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

    public init() {}

    /// Any share currently scanning or enriching.
    public var isAnyBusy: Bool { byShare.values.contains(where: { $0.isBusy }) }

    /// Display names of shares currently busy (for the banner text).
    public var busyShareNames: [String] {
        byShare.values.filter(\.isBusy).map(\.name).sorted()
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

    /// A reporter that forwards scanner events onto this model on the main actor.
    /// Held by the scanner/enricher (which run off-main), so passing it across the
    /// actor boundary is safe.
    public nonisolated func reporter() -> ShareScanReporter {
        ShareScanReporter(
            scanStarted: { [weak self] id, name in Task { @MainActor in self?.scanStarted(shareID: id, name: name) } },
            scanProgress: { [weak self] id, count in Task { @MainActor in self?.scanProgress(shareID: id, itemsFound: count) } },
            scanFinished: { [weak self] id in Task { @MainActor in self?.scanFinished(shareID: id) } },
            enrichStarted: { [weak self] id in Task { @MainActor in self?.enrichStarted(shareID: id) } },
            enrichFinished: { [weak self] id in Task { @MainActor in self?.enrichFinished(shareID: id) } }
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
