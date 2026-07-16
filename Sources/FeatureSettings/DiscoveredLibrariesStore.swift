#if canImport(SwiftUI)
import Foundation
import Observation
import CoreModels

/// Holds the cross-account library discovery result for Settings.
///
/// WHY THIS EXISTS (not just a `LoadState` value passed into `SettingsView`):
/// library discovery runs on every Settings appearance and mutates its state
/// (`idle → loading → loaded`) — which, on tvOS, lands *during* the tab
/// focus-flip. When the state was threaded through `SettingsView` as a plain
/// value, every change rebuilt `SettingsView` and re-rendered its ROOT list
/// (the focusable rows) mid-flip, freeing a view backing the focus engine still
/// held for its flip snapshot → `setToViewXFlippedScreenShot:` use-after-free.
///
/// By moving the state behind an `@Observable` reference that ONLY the library
/// detail pages read (`context.discoveredLibraries`, evaluated lazily inside
/// `destination(for:)`), a load no longer re-renders the root list at all —
/// only the pushed detail view that actually displays libraries observes it,
/// and that page isn't on screen during the tab flip. This is the SwiftUI
/// data-flow rule (narrow observation to the view that reads the value) applied
/// to fix the crash at its root instead of masking the timing.
@MainActor
@Observable
public final class DiscoveredLibrariesStore {
    public var state: LoadState<[AggregatedLibrary]> = .idle
    /// Accounts whose libraries are being refreshed after a profile toggle.
    /// Existing loaded rows remain visible while this is non-empty so unrelated
    /// server cards do not collapse and disturb tvOS focus/scroll geometry.
    public var refreshingAccountIDs: Set<String> = []

    public init() {}

    public func beginRefresh(accountIDs: Set<String>) {
        refreshingAccountIDs.formUnion(accountIDs)
        if state.value == nil {
            state = .loading
        }
    }

    public func finishRefresh(with libraries: [AggregatedLibrary]) {
        state = libraries.isEmpty ? .empty : .loaded(libraries)
        refreshingAccountIDs.removeAll()
    }
}
#endif
