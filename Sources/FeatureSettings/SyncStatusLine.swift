#if canImport(SwiftUI)
import SwiftUI

/// Renders the iCloud sync status line, evaluating its text **inside its own
/// body**.
///
/// The text is built from `CloudSyncStatus`, which publishes on every phase
/// change, record count and completion timestamp — several times a second while
/// a sync runs. It used to be built in `RootView.body` and passed down as a
/// finished `Text`, which made the *root of the app* a subscriber of that model:
/// each tick re-evaluated `RootView`, and a root re-evaluation dirties every
/// view beneath it. In a Time Profiler trace that showed up as
/// `AG::Graph::propagate_dirty` and `AG::Subgraph::update` at the very top of
/// the main thread's profile.
///
/// Deferring the read to here confines the invalidation to this one line.
public struct SyncStatusProvider {
    let make: () -> Text?

    /// - Parameter make: called from ``SyncStatusLine``'s body, never earlier.
    public init(_ make: @escaping () -> Text?) { self.make = make }
}

struct SyncStatusLine: View {
    let provider: SyncStatusProvider

    var body: some View {
        provider.make()
    }
}
#endif
