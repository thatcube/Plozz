#if os(iOS)
import CoreUI
import MediaDownloads

extension DownloadedMediaRecord {
    /// Map a download record onto the view layer's neutral badge state.
    ///
    /// CoreUI sits below `MediaDownloads` in the module graph, so the badge can't
    /// read a record directly — the shell adapts it here. One definition so the
    /// Continue Watching rail and the episode rows can't drift on what "paused"
    /// or "queued" looks like.
    var badgeState: MediaDownloadBadgeState? {
        switch status {
        case .completed: return .completed
        case .downloading, .queued: return .inProgress(fraction: fractionCompleted ?? 0)
        case .paused: return .paused(fraction: fractionCompleted ?? 0)
        case .failed: return .failed
        }
    }
}
#endif
