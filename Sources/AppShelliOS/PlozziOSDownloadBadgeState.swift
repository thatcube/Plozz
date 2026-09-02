#if os(iOS)
import CoreModels
import CoreUI
import MediaDownloads
import Foundation

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
        case .preparing, .downloading, .queued:
            return .inProgress(fraction: fractionCompleted)
        case .paused: return .paused(fraction: fractionCompleted)
        case .failed: return .failed
        }
    }

    /// The coarse state the ACTION CATALOG needs — which of start / pause /
    /// resume / remove to offer. Separate from `badgeState` (what to draw) so the
    /// two can't be conflated: a failed download shows an error glyph but offers
    /// "Resume".
    var menuState: MediaItemDownloadState {
        switch status {
        case .queued, .preparing, .downloading: return .inFlight
        case .paused, .failed: return .interrupted
        case .completed: return .downloaded
        }
    }
}

extension PlozziOSAppModel {
    /// Run a download action from any menu. One implementation so the Continue
    /// Watching card, the episode rows and the detail page can't drift on what
    /// "Resume" does — previously these lived only inside the episode row view,
    /// which is why no other surface could offer them.
    func performDownloadMenuAction(_ action: MediaItemAction, on item: MediaItem) async {
        switch action {
        case .startDownload:
            guard let provider = provider(for: item) else { return }
            _ = try? await downloads.enqueue(item: item, provider: provider)
        case .pauseDownload:
            guard let record = downloads.cachedRecord(forSelectedVersionOf: item) else { return }
            await downloads.pause(record)
        case .resumeDownload:
            guard let record = downloads.cachedRecord(forSelectedVersionOf: item) else { return }
            await downloads.resume(record)
        case .removeDownload:
            guard let record = downloads.cachedRecord(forSelectedVersionOf: item) else { return }
            await downloads.remove(record)
        default:
            break
        }
    }
}
#endif
