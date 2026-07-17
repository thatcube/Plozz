#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import CoreUI
import CoreModels

/// The in-player subtitle **search + download** screen, extracted from
/// `PlayerControls`. Shows a spinner while searching, the ranked results (with
/// Forced/SDH badges) to pick from, or a friendly empty/error state. Picking a
/// result downloads it server-side and hot-loads it into the running player.
///
/// Pure content: it reads `model.subtitleDownloadState` and drives
/// `actions.downloadRemoteSubtitle`, threading the shared `@FocusState` so its
/// result rows participate in the same focus engine. No panel morph coupling.
struct SubtitleDownloadScreen: View {
    let model: PlayerControlsModel
    let actions: PlayerOptionsActions
    @FocusState.Binding var focus: PlayerControls.FocusSlot?

    @ViewBuilder
    var body: some View {
        switch model.subtitleDownloadState {
        case .idle, .searching:
            subtitleDownloadStatus(
                systemImage: "magnifyingglass",
                title: "Searching for subtitles…",
                detail: "Looking through your server's subtitle source.",
                showSpinner: true
            )
        case .results(let subs):
            subtitleResultsList(subs)
        case .empty:
            subtitleDownloadStatus(
                systemImage: "text.magnifyingglass",
                title: "No subtitles found",
                detail: "Nothing matched in your language. If this is a Plex or Jellyfin server, make sure a subtitle source (e.g. OpenSubtitles) is set up on the server."
            )
        case .downloading:
            subtitleDownloadStatus(
                systemImage: "arrow.down.circle",
                title: "Downloading subtitle…",
                detail: "Fetching it and loading it into the player.",
                showSpinner: true
            )
        case .added:
            subtitleDownloadStatus(
                systemImage: "checkmark.circle.fill",
                title: "Subtitle added",
                detail: "It's now playing and available in your subtitle list."
            )
        case .failed:
            subtitleDownloadStatus(
                systemImage: "exclamationmark.triangle",
                title: "Couldn't get that subtitle",
                detail: "Something went wrong searching or downloading. Try again."
            )
        }
    }

    private func subtitleDownloadStatus(systemImage: String, title: String, detail: String, showSpinner: Bool = false) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                if showSpinner {
                    ProgressView()
                } else {
                    Image(systemName: systemImage).font(.title3)
                }
                Text(title).font(.callout.weight(.semibold))
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 40)
        // Fill the pinned Download-screen height and centre, so the spinner /
        // message sits in the middle of the box rather than jammed top-left.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func subtitleResultsList(_ subs: [RemoteSubtitle]) -> some View {
        // A plain column (NOT a ScrollView): the enclosing `morphingBody` already
        // provides the scroll + height measurement that drives the open/height
        // morph, exactly like the track list. A nested ScrollView here is greedy
        // vertically, breaks that measurement (so the panel wouldn't animate open),
        // and reads as janky.
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(subs.prefix(30).enumerated()), id: \.element.id) { index, sub in
                Button {
                    actions.downloadRemoteSubtitle(sub)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        MarqueeText(text: Self.remoteSubtitleTitle(sub), font: .body)
                        Text(Self.remoteSubtitleDetail(sub))
                            .font(.caption2)
                            .playerMenuRowSecondary()
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlayerMenuRowButtonStyle())
                .focusEffectDisabled()
                .focused($focus, equals: .row(index))
            }
        }
        .padding(.horizontal, 14)
    }

    /// The candidate's display name, falling back to language when unnamed.
    private static func remoteSubtitleTitle(_ sub: RemoteSubtitle) -> String {
        if !sub.name.isEmpty { return sub.name }
        if let language = sub.language { return SubtitleLanguageCatalog.displayName(forCode: language) ?? language }
        return "Subtitle"
    }

    /// The language · downloads · badges line beneath a candidate. The provider is
    /// omitted for OpenSubtitles (Plex's only source, and Jellyfin's usual one — so
    /// it's noise); a *different* provider is shown since then it's informative.
    private static func remoteSubtitleDetail(_ sub: RemoteSubtitle) -> String {
        var parts: [String] = []
        if let provider = sub.providerName, !provider.isEmpty,
           !provider.lowercased().replacingOccurrences(of: " ", with: "").contains("opensubtitles") {
            parts.append(provider)
        }
        if let language = sub.language,
           let name = SubtitleLanguageCatalog.displayName(forCode: language) { parts.append(name) }
        if let count = sub.downloadCount, count > 0 {
            let formatted = NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal)
            parts.append("\(formatted) downloads")
        }
        if sub.isForced { parts.append("Forced") }
        if sub.isHearingImpaired { parts.append("SDH") }
        return parts.isEmpty ? "Tap to download" : parts.joined(separator: " · ")
    }
}

/// The compact subtitle **timing** screen reached from the header Sync chip:
/// nudge the primary subtitle earlier/later to line it up with the audio. A
/// single − / value / + stepper in 50 ms steps (matching the Speed stepper's
/// look), with a dynamic hint stating the current earlier/later result. Only
/// offered when the app's overlay owns the active subtitle, so the chip that
/// opens it is gated the same way. Extracted from `PlayerControls`; the shared
/// `delayLabel` / `subtitleSyncHint` formatters stay on `PlayerControls` because
/// the A/V Sync pane uses them too.
struct SubtitleSyncScreen: View {
    let model: PlayerControlsModel
    let actions: PlayerOptionsActions
    @FocusState.Binding var focus: PlayerControls.FocusSlot?

    var body: some View {
        VStack(spacing: 20) {
            delayStepper(
                value: model.subtitleDelaySeconds,
                minusSlot: 0,
                plusSlot: 1,
                step: 0.05,
                onAdjust: { actions.setSubtitleDelay(model.subtitleDelaySeconds + $0) }
            )
            Text(PlayerControls.subtitleSyncHint(model.subtitleDelaySeconds))
                .font(.callout)
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .animation(.easeInOut(duration: 0.15), value: model.subtitleDelaySeconds)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 28)
    }

    /// A compact − / value / + stepper for the subtitle-sync screen. The ± are
    /// discrete focusable chips (bound to `minusSlot` / `plusSlot`) that reuse the
    /// Speed stepper's circular `StepperButtonStyle`; the live value sits centred
    /// between them in ms.
    private func delayStepper(
        value: TimeInterval,
        minusSlot: Int,
        plusSlot: Int,
        step: TimeInterval,
        onAdjust: @escaping (TimeInterval) -> Void
    ) -> some View {
        HStack(spacing: 24) {
            Button { onAdjust(-step) } label: {
                Image(systemName: "minus")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 56, height: 56)
            }
            .buttonStyle(StepperButtonStyle())
            .focused($focus, equals: .row(minusSlot))

            Text(PlayerControls.delayLabel(value))
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.16), value: value)
                .frame(minWidth: 104)

            Button { onAdjust(step) } label: {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 56, height: 56)
            }
            .buttonStyle(StepperButtonStyle())
            .focused($focus, equals: .row(plusSlot))
        }
        .padding(.vertical, 4)
    }
}
#endif
