#if canImport(SwiftUI)
import SwiftUI

/// Download state as the *view layer* needs it, deliberately independent of
/// `MediaDownloads.DownloadedMediaRecord`.
///
/// CoreUI sits below the download stack (it depends only on CoreModels and
/// MetadataKit), so importing `MediaDownloads` here would invert the module
/// graph and trip the architecture guard. Each shell maps its own record into
/// this, which also keeps the badge usable from previews and tests with no
/// download machinery at all.
public enum MediaDownloadBadgeState: Equatable, Sendable {
    /// Fully downloaded and playable offline.
    case completed
    /// Queued or actively fetching; `nil` means the byte total is not known yet.
    case inProgress(fraction: Double?)
    /// Interrupted with a recoverable partial file.
    case paused(fraction: Double?)
    /// Fatal error; needs user action.
    case failed
}

/// The download affordance drawn on media artwork — a filled glyph when the item
/// is on-device, a progress ring while it transfers.
///
/// Shared so a Continue Watching card and an episode card report a download the
/// same way. Sized by the caller (`resumeChipAccessorySize` on a resume chip) so
/// it matches whatever typography it sits beside instead of carrying its own
/// platform-specific point size.
public struct MediaDownloadBadge: View {
    private let state: MediaDownloadBadgeState
    private let size: CGFloat

    public init(state: MediaDownloadBadgeState, size: CGFloat) {
        self.state = state
        self.size = size
    }

    public var body: some View {
        // Flat: the artwork scrim carries legibility for every control on a card.
        content
            .frame(width: size, height: size)
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: size))
                .foregroundStyle(.white.opacity(0.85))
                .accessibilityLabel("Downloaded")
        case .inProgress(let fraction):
            progress(fraction: fraction)
                .accessibilityLabel("Downloading")
        case .paused(let fraction):
            progress(fraction: fraction, dimmed: true)
                .accessibilityLabel("Download paused")
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: size))
                .foregroundStyle(.orange)
                .accessibilityLabel("Download failed")
        }
    }

    @ViewBuilder
    private func progress(fraction: Double?, dimmed: Bool = false) -> some View {
        if let fraction {
            ring(fraction: fraction, dimmed: dimmed)
        } else if dimmed {
            Image(systemName: "pause.circle.fill")
                .font(.system(size: size))
                .foregroundStyle(.white.opacity(0.6))
        } else {
            ProgressView()
                .controlSize(size >= 24 ? .regular : .small)
                .tint(.white)
        }
    }

    private func ring(fraction: Double, dimmed: Bool = false) -> some View {
        // Match the filled `arrow.down.circle.fill` glyph's visible circle (which
        // is inset from its point size) and use a proportional stroke so the ring
        // reads at the same weight as the icon at every size.
        let diameter = size * 0.86
        let lineWidth = max(size * 0.18, 2)
        return ZStack {
            Circle()
                .stroke(Color.white.opacity(0.28), lineWidth: lineWidth)
            Circle()
                // A floor keeps a just-queued download visible as an arc rather
                // than an empty circle indistinguishable from the track.
                .trim(from: 0, to: max(0.02, fraction))
                .stroke(
                    Color.white.opacity(dimmed ? 0.5 : 1),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.25), value: fraction)
        }
        .frame(width: diameter, height: diameter)
    }
}
#endif
