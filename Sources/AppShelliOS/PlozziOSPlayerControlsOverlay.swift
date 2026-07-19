#if os(iOS)
import CoreModels
import FeaturePlayback
import SwiftUI

private enum PlozziOSPlayerSheet: String, Identifiable {
    case info
    case speed
    case sync

    var id: Self { self }
}

struct PlozziOSPlayerControlsOverlay: View {
    let viewModel: PlayerViewModel
    let onClose: () -> Void

    @State private var controlsVisible = true
    @State private var scrubSeconds: TimeInterval = 0
    @State private var isScrubbing = false
    @State private var presentedSheet: PlozziOSPlayerSheet?
    @State private var autoHideTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.clear
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { toggleControls() }

            if controlsVisible {
                LinearGradient(
                    colors: [.black.opacity(0.65), .clear, .black.opacity(0.82)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)

                PlozziOSPlayerTopBar(
                    title: viewModel.controls.title,
                    subtitle: viewModel.controls.subtitle,
                    onClose: onClose
                )

                PlozziOSPlayerTransport(
                    viewModel: viewModel,
                    displayedSeconds: isScrubbing
                        ? scrubSeconds
                        : viewModel.controls.currentSeconds,
                    onScrubChanged: { value in
                        scrubSeconds = value
                        noteInteraction()
                    },
                    onScrubEditingChanged: { editing in
                        isScrubbing = editing
                        if editing {
                            scrubSeconds = viewModel.controls.currentSeconds
                            cancelAutoHide()
                        } else {
                            viewModel.requestSeek(to: scrubSeconds)
                            scheduleAutoHide()
                        }
                    },
                    onSkipBackward: {
                        seek(by: -viewModel.controls.skipBackwardInterval.seconds)
                    },
                    onPlayPause: {
                        viewModel.togglePlayPause()
                        noteInteraction()
                    },
                    onSkipForward: {
                        seek(by: viewModel.controls.skipForwardInterval.seconds)
                    },
                    onShowInfo: {
                        presentedSheet = .info
                        cancelAutoHide()
                    },
                    onShowSpeed: {
                        presentedSheet = .speed
                        cancelAutoHide()
                    },
                    onShowSync: {
                        presentedSheet = .sync
                        cancelAutoHide()
                    },
                    onInteraction: noteInteraction
                )
            }

            if viewModel.controls.skipButtonVisible {
                Button {
                    viewModel.skipActiveSegment()
                    noteInteraction()
                } label: {
                    Text(skipTitle)
                        .font(.headline)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(24)
            }

            if viewModel.controls.upNextActive,
               let upNext = viewModel.controls.upNext {
                PlozziOSUpNextCard(
                    info: upNext,
                    onPlay: {
                        viewModel.playEpisode(upNext.episode)
                    },
                    onDismiss: {
                        viewModel.dismissUpNextCard()
                    }
                )
            }
        }
        .animation(.easeInOut(duration: 0.2), value: controlsVisible)
        .onAppear { scheduleAutoHide() }
        .onDisappear { cancelAutoHide() }
        .onChange(of: viewModel.controls.intendsPause) { _, paused in
            if paused {
                controlsVisible = true
                cancelAutoHide()
            } else {
                scheduleAutoHide()
            }
        }
        .sheet(item: $presentedSheet, onDismiss: scheduleAutoHide) { sheet in
            switch sheet {
            case .info:
                PlozziOSPlaybackInfoSheet(viewModel: viewModel)
            case .speed:
                PlozziOSPlaybackSpeedSheet(viewModel: viewModel)
            case .sync:
                PlozziOSPlaybackSyncSheet(viewModel: viewModel)
            }
        }
    }

    private var skipTitle: String {
        viewModel.controls.activeSkipSegment?.kind.skipActionLabel ?? "Skip"
    }

    private func toggleControls() {
        controlsVisible.toggle()
        if controlsVisible {
            scheduleAutoHide()
        } else {
            cancelAutoHide()
        }
    }

    private func seek(by interval: TimeInterval) {
        let target = min(
            max(viewModel.controls.currentSeconds + interval, 0),
            viewModel.controls.duration
        )
        viewModel.requestSeek(to: target)
        noteInteraction()
    }

    private func noteInteraction() {
        controlsVisible = true
        scheduleAutoHide()
    }

    private func scheduleAutoHide() {
        cancelAutoHide()
        guard !viewModel.controls.intendsPause, presentedSheet == nil, !isScrubbing else {
            return
        }
        autoHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            controlsVisible = false
        }
    }

    private func cancelAutoHide() {
        autoHideTask?.cancel()
        autoHideTask = nil
    }
}

private struct PlozziOSPlayerTopBar: View {
    let title: String
    let subtitle: String
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.headline)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Close player")

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.top, 3)

            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding()
    }
}

private struct PlozziOSPlayerTransport: View {
    let viewModel: PlayerViewModel
    let displayedSeconds: TimeInterval
    let onScrubChanged: (TimeInterval) -> Void
    let onScrubEditingChanged: (Bool) -> Void
    let onSkipBackward: () -> Void
    let onPlayPause: () -> Void
    let onSkipForward: () -> Void
    let onShowInfo: () -> Void
    let onShowSpeed: () -> Void
    let onShowSync: () -> Void
    let onInteraction: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(playbackTime(displayedSeconds))
                Spacer()
                Text("-\(playbackTime(max(viewModel.controls.duration - displayedSeconds, 0)))")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.85))

            Slider(
                value: Binding(
                    get: { displayedSeconds },
                    set: onScrubChanged
                ),
                in: 0...max(viewModel.controls.duration, 1),
                onEditingChanged: onScrubEditingChanged
            )
            .tint(.white)
            .accessibilityLabel("Playback position")

            HStack(spacing: 22) {
                Button(action: onSkipBackward) {
                    Image(systemName: "gobackward.\(viewModel.controls.skipBackwardInterval.rawValue)")
                }
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("Skip backward")

                Button(action: onPlayPause) {
                    Image(
                        systemName: viewModel.controls.intendsPause
                            ? "play.fill"
                            : "pause.fill"
                    )
                }
                .font(.title)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel(
                    viewModel.controls.intendsPause ? "Play" : "Pause"
                )

                Button(action: onSkipForward) {
                    Image(systemName: "goforward.\(viewModel.controls.skipForwardInterval.rawValue)")
                }
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("Skip forward")

                Spacer(minLength: 8)

                playbackOptions

                Button(action: onShowInfo) {
                    Image(systemName: "info.circle")
                }
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("Playback information")
            }
            .font(.title3)
            .foregroundStyle(.white)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    private var playbackOptions: some View {
        Menu {
            if !viewModel.controls.audioOptions.isEmpty || supportsDialogEnhance {
                Menu("Audio") {
                    ForEach(viewModel.controls.audioOptions) { option in
                        Button {
                            viewModel.selectAudioOption(id: option.id)
                            onInteraction()
                        } label: {
                            if option.isSelected {
                                Label(option.title, systemImage: "checkmark")
                            } else {
                                Text(option.title)
                            }
                        }
                    }
                    if !viewModel.controls.audioOptions.isEmpty,
                       supportsDialogEnhance {
                        Divider()
                    }
                    if supportsDialogEnhance {
                        Toggle(
                            "Dialog Enhance",
                            isOn: Binding(
                                get: {
                                    viewModel.controls.dialogEnhanceEnabled
                                },
                                set: {
                                    viewModel.setDialogEnhanceEnabled($0)
                                    onInteraction()
                                }
                            )
                        )
                    }
                }
            }

            if !viewModel.controls.subtitleOptions.isEmpty {
                Menu("Subtitles") {
                    ForEach(viewModel.controls.subtitleOptions) { option in
                        Button {
                            viewModel.selectSubtitleOption(id: option.id)
                            onInteraction()
                        } label: {
                            if option.isSelected {
                                Label(option.title, systemImage: "checkmark")
                            } else {
                                Text(option.title)
                            }
                        }
                    }
                }
            }

            if viewModel.controls.engineCapabilities.contains(.playbackSpeed) {
                Button("Playback Speed", systemImage: "speedometer") {
                    onShowSpeed()
                }
            }

            if supportsSync {
                Button("Playback Sync", systemImage: "slider.horizontal.3") {
                    onShowSync()
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel("Audio, subtitles, and speed")
    }

    private var supportsSync: Bool {
        viewModel.controls.engineCapabilities.contains(.audioDelay)
            || viewModel.controls.subtitleDelayAdjustable
    }

    private var supportsDialogEnhance: Bool {
        viewModel.controls.engineCapabilities.contains(.dialogEnhance)
    }

    private func playbackTime(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds.rounded()), 0)
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let remainder = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%d:%02d", minutes, remainder)
    }
}

private struct PlozziOSPlaybackSpeedSheet: View {
    @Environment(\.dismiss) private var dismiss
    let viewModel: PlayerViewModel

    private let presets: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    var body: some View {
        NavigationStack {
            Form {
                Section("Fine Control") {
                    Slider(
                        value: Binding(
                            get: { viewModel.controls.playbackSpeed },
                            set: { viewModel.setPlaybackSpeed($0) }
                        ),
                        in: 0.25...2,
                        step: 0.05
                    )
                    Text(
                        viewModel.controls.playbackSpeed,
                        format: .number.precision(.fractionLength(2))
                    )
                    .monospacedDigit()
                    .frame(maxWidth: .infinity)
                }

                Section("Presets") {
                    ForEach(presets, id: \.self) { rate in
                        Button {
                            viewModel.setPlaybackSpeed(rate)
                        } label: {
                            HStack {
                                Text("\(rate, format: .number)×")
                                Spacer()
                                if abs(viewModel.controls.playbackSpeed - rate) < 0.01 {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Playback Speed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

private struct PlozziOSPlaybackInfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    let viewModel: PlayerViewModel

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(viewModel.controls.infoHeadline)
                        .font(.headline)
                    if !viewModel.controls.overview.isEmpty {
                        Text(viewModel.controls.overview)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button("Restart from Beginning", systemImage: "arrow.counterclockwise") {
                        viewModel.requestSeek(to: 0)
                        dismiss()
                    }
                    if viewModel.controls.hasPreviousEpisode,
                       let previous = viewModel.previousEpisode {
                        Button("Previous Episode", systemImage: "backward.end.fill") {
                            viewModel.playEpisode(previous)
                            dismiss()
                        }
                    }
                    if viewModel.controls.hasNextEpisode {
                        Button("Next Episode", systemImage: "forward.end.fill") {
                            viewModel.playNextEpisode()
                            dismiss()
                        }
                    }
                }

                if !viewModel.controls.infoBadges.isEmpty {
                    Section("Media") {
                        ForEach(viewModel.controls.infoBadges, id: \.self) { badge in
                            Text(badge.label)
                        }
                    }
                }
            }
            .navigationTitle("Now Playing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct PlozziOSPlaybackSyncSheet: View {
    @Environment(\.dismiss) private var dismiss
    let viewModel: PlayerViewModel

    var body: some View {
        NavigationStack {
            Form {
                if viewModel.controls.engineCapabilities.contains(.audioDelay) {
                    Section("Audio Delay") {
                        Slider(
                            value: Binding(
                                get: { viewModel.controls.audioDelaySeconds },
                                set: { viewModel.setAudioDelay($0) }
                            ),
                            in: -2...2,
                            step: 0.05
                        )
                        Text(
                            viewModel.controls.audioDelaySeconds,
                            format: .number.precision(.fractionLength(2))
                        )
                        .foregroundStyle(.secondary)
                    }
                }

                if viewModel.controls.subtitleDelayAdjustable {
                    Section("Subtitle Delay") {
                        Slider(
                            value: Binding(
                                get: { viewModel.controls.subtitleDelaySeconds },
                                set: { viewModel.setSubtitleDelay($0) }
                            ),
                            in: -2...2,
                            step: 0.05
                        )
                        Text(
                            viewModel.controls.subtitleDelaySeconds,
                            format: .number.precision(.fractionLength(2))
                        )
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Playback Sync")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

private struct PlozziOSUpNextCard: View {
    let info: UpNextInfo
    let onPlay: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(info.eyebrow)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(info.showName)
                    .font(.headline)
                    .lineLimit(1)
                if let metaLine = info.metaLine {
                    Text(metaLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button("Play", systemImage: "play.fill", action: onPlay)
                .buttonStyle(.borderedProminent)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss Up Next")
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .foregroundStyle(.white)
        .frame(maxWidth: 430)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(24)
    }
}
#endif
