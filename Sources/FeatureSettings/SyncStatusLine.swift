#if canImport(SwiftUI)
import SwiftUI

public struct SyncStatusPresentation {
    let summary: LocalizedStringResource
    let isSyncing: Bool

    public init(summary: LocalizedStringResource, isSyncing: Bool) {
        self.summary = summary
        self.isSyncing = isSyncing
    }
}

/// Renders iCloud sync state and owns its delayed long-running feedback.
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
    let make: () -> SyncStatusPresentation

    /// - Parameter make: called from ``SyncStatusLine``'s body, never earlier.
    public init(_ make: @escaping () -> SyncStatusPresentation) { self.make = make }
}

struct SyncStatusLine: View {
    let provider: SyncStatusProvider
    @State private var longSyncMessageIndex: Int?

    private static let longSyncMessages: [LocalizedStringResource] = [
        "Making every screen agree…",
        "Counting clouds…",
        "Teaching devices to share…",
        "Moving tiny settings around…",
        "Checking the other couch…",
        "Aligning your watch universe…",
        "Giving iCloud a gentle nudge…",
        "Untangling the cloud…",
        "Comparing notes with your devices…",
        "Almost certainly syncing…"
    ]

    var body: some View {
        let status = provider.make()
        let isSyncing = status.isSyncing
        HStack(spacing: 12) {
            if isSyncing {
                ProgressView()
                    .controlSize(.small)
            }
            Text(currentMessage(for: status))
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.3), value: longSyncMessageIndex)
        }
        .task(id: isSyncing) {
            longSyncMessageIndex = nil
            guard isSyncing else { return }

            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }

            var index = 0
            while !Task.isCancelled {
                longSyncMessageIndex = index
                try? await Task.sleep(for: .seconds(3.5))
                guard !Task.isCancelled else { return }
                index = (index + 1) % Self.longSyncMessages.count
            }
        }
    }

    private func currentMessage(
        for status: SyncStatusPresentation
    ) -> LocalizedStringResource {
        guard
            status.isSyncing,
            let longSyncMessageIndex
        else {
            return status.summary
        }
        return Self.longSyncMessages[longSyncMessageIndex]
    }
}
#endif
