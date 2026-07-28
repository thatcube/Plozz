#if os(iOS)
import CoreGraphics
import CoreModels
import FeaturePlayback
import AVKit
import SwiftUI
import CoreUI

private enum PlozziOSPlayerSheet: String, Identifiable {
    case info
    case speed
    case subtitles
    case sync

    var id: Self { self }
}

struct PlozziOSPlayerControlsOverlay: View {
    let viewModel: PlayerViewModel
    let onClose: () -> Void

    @State private var controlsVisible = true
    @State private var scrubSeconds: TimeInterval = 0
    @State private var isScrubbing = false
    @State private var scrubPreviewCoordinator: ScrubPreviewCoordinator?
    @State private var presentedSheet: PlozziOSPlayerSheet?
    @State private var autoHideTask: Task<Void, Never>?
    @StateObject private var pictureInPicture = PlozziOSPictureInPictureController()

    var body: some View {
        ZStack {
            Color.clear
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { toggleControls() }

            if isPlayingElsewhere {
                PlozziOSExternalPlaybackPlaceholder(
                    routeName: viewModel.externalPlaybackRouteName,
                    isPictureInPicture: pictureInPicture.isActive
                )
            }

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
                    isScrubbing: isScrubbing,
                    scrubPreviewImage: scrubPreviewCoordinator?.image,
                    showsScrubPreview: scrubPreviewCoordinator != nil,
                    pictureInPictureAvailable: pictureInPicture.isAvailable,
                    onTogglePictureInPicture: {
                        pictureInPicture.toggle()
                        noteInteraction()
                    },
                    onScrubChanged: { value in
                        scrubSeconds = value
                        scrubPreviewCoordinator?.update(for: value)
                        noteInteraction()
                    },
                    onScrubEditingChanged: { editing in
                        isScrubbing = editing
                        if editing {
                            scrubSeconds = viewModel.controls.currentSeconds
                            cancelAutoHide()
                        } else {
                            viewModel.requestSeek(to: scrubSeconds)
                            scrubPreviewCoordinator?.clear()
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
                    onShowSubtitles: {
                        presentedSheet = .subtitles
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

            if viewModel.controls.isPresentingUpNext,
               let upNext = viewModel.controls.upNext {
                PlozziOSUpNextCard(
                    info: upNext,
                    countdownRemaining: upNextCountdownRemaining,
                    onPlay: { viewModel.playEpisode(upNext.episode) },
                    onDismiss: { viewModel.dismissUpNextCard() }
                )
            }
        }
        .animation(.easeInOut(duration: 0.2), value: controlsVisible)
        .onAppear { scheduleAutoHide() }
        .onAppear { configureScrubPreview() }
        .onAppear { attachPictureInPicture() }
        // The presenting layer does not exist until the native path has loaded,
        // and an engine hand-off can replace it mid-session, so re-read it
        // whenever playback becomes ready rather than once at appear.
        .onChange(of: viewModel.phase) { _, _ in attachPictureInPicture() }
        // No AirPlay equivalent yet, and not for want of trying: the engine
        // declares its native subtitle renditions in the master playlist, but the
        // wireless AirPlay path serves the media playlist so AVPlayer will not
        // reject a DV/HDR master on an SDR receiver. A media playlist carries no
        // EXT-X-MEDIA tags, so there is no legible track to select and the call
        // changes nothing. Tracked upstream as AetherEngine#227.
        .onDisappear { pictureInPicture.detach() }
        .onDisappear {
            cancelAutoHide()
            scrubPreviewCoordinator?.clear()
        }
        .onChange(of: viewModel.scrubPreview) {
            configureScrubPreview()
        }
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
            case .subtitles:
                PlozziOSSubtitleOptionsSheet(viewModel: viewModel)
            case .sync:
                PlozziOSPlaybackSyncSheet(viewModel: viewModel)
            }
        }
    }

    private var skipTitle: String {
        viewModel.controls.activeSkipSegment?.kind.skipActionLabel ?? "Skip"
    }

    private var upNextCountdownRemaining: TimeInterval? {
        guard let deadline = viewModel.controls.upNextAdvanceAtSeconds else { return nil }
        return max(deadline - viewModel.controls.currentSeconds, 0)
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
        // Auto-hide exists to get the chrome out of the way of the video. With
        // the video on a TV or in a PiP window there is nothing to reveal, and
        // hiding leaves the user staring at a placeholder with no way to pause
        // without tapping first.
        guard !isPlayingElsewhere else { return }
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

    /// True while the frames are presenting somewhere other than this screen.
    private var isPlayingElsewhere: Bool {
        pictureInPicture.isActive || viewModel.externalPlaybackRouteName != nil
    }

    private func attachPictureInPicture() {
        guard let engine = viewModel.pictureInPictureEngine else { return }
        pictureInPicture.attach(engine: engine)
        pictureInPicture.onRestoreUI = { @MainActor in
            // Nothing to rebuild today: the player stays mounted behind the PiP
            // window. The handler still has to run so AVKit completes the
            // restore rather than leaving the window half-dismissed.
        }
    }

    private func configureScrubPreview() {
        scrubPreviewCoordinator?.clear()
        scrubPreviewCoordinator = viewModel.makeScrubPreviewCoordinator()
        scrubPreviewCoordinator?.prefetch()
    }
}

/// The system AirPlay route picker.
///
/// Nothing else is needed to AirPlay a locally-remuxed stream: AetherEngine
/// watches `isExternalPlaybackActive` on its own AVPlayer and, when a wireless
/// receiver picks up, reloads at the current position with the device's LAN IP
/// swapped in for 127.0.0.1 and the MEDIA playlist forced, because the Apple TV
/// cannot fetch segments from the phone's loopback and rejects a DV/HDR master
/// playlist on an SDR receiver. That makes this true AirPlay video rather than
/// screen mirroring. A wired HDMI display is deliberately left on the loopback.
/// Shown when the video has moved off this screen.
///
/// The local surface goes black in both cases, because the frames are being
/// presented somewhere else: a Picture in Picture window, or an AirPlay
/// receiver. A black rectangle with floating subtitles over it reads as a
/// failure, so say plainly where the video went.
private struct PlozziOSExternalPlaybackPlaceholder: View {
    let routeName: String?
    let isPictureInPicture: Bool

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: isPictureInPicture ? "pip" : "airplayvideo")
                .font(.system(size: 52, weight: .light))
            Text(title)
                .font(.title3.weight(.semibold))
            if let detail {
                Text(detail)
                    .font(.subheadline)
                    .plozzForeground(.secondary)
            }
        }
        .foregroundStyle(.white)
        .multilineTextAlignment(.center)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Opaque on purpose. The shared player keeps rendering its subtitle
        // overlay against a black surface, and those cues are meaningless here
        // while the frames they belong to are on another screen, so this covers
        // them rather than letting them float over an empty rectangle.
        .background(Color.black)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var title: LocalizedStringResource {
        if isPictureInPicture { return "Playing in Picture in Picture" }
        if let routeName { return "Playing on \(routeName)" }
        return "Playing on AirPlay"
    }

    private var detail: LocalizedStringResource? {
        isPictureInPicture ? "Tap the window to bring playback back here." : nil
    }
}

private struct PlozziOSAirPlayRouteButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        // Surfaces Apple TV class receivers ahead of audio-only routes.
        view.prioritizesVideoDevices = true
        view.tintColor = .white
        view.activeTintColor = .white
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

private struct PlozziOSPlayerTopBar: View {
    let title: String   // l10n:content — media title from the server
    let subtitle: String   // l10n:content — media subtitle from the server
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
                        .plozzForeground(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.top, 3)

            Spacer(minLength: 0)

            PlozziOSAirPlayRouteButton()
                .frame(width: 44, height: 44)
                .accessibilityLabel(Text(verbatim: "AirPlay"))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding()
    }
}

private extension View {
    /// Gives a transport glyph a real 44pt touch target.
    ///
    /// The sizing has to live on the button's LABEL. Applied to the `Button`
    /// itself, `.frame(minWidth: 44, minHeight: 44)` only enlarges the layout
    /// slot the button is centred in; the button stays as big as its label, which
    /// for these glyphs is around 20pt. The overlay puts a full-screen tap layer
    /// behind the controls to toggle them, so every tap that landed in the gap
    /// between the glyph and its 44pt slot fell through to that layer: pressing
    /// play or skip read as tapping off the controls and dismissed them, and the
    /// buttons appeared to do nothing. `contentShape` makes the padded area part
    /// of the label rather than empty space the tap passes through.
    func playerTransportGlyph(font: Font = .title3) -> some View {
        self
            .font(font)
            .foregroundStyle(.white)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
    }
}

/// The transport's "..." menu, driven by values rather than by the view model.
///
/// Split out so the playback clock cannot reach it: `PlayerControlsModel` is
/// @Observable, and a `Menu` whose content closure reads it re-evaluates on
/// every one of the roughly ten position updates a second, which makes an open
/// menu's rows visibly flash. Holding plain values instead means SwiftUI only
/// rebuilds the menu when a track list, a capability, or the Dialog Enhance
/// state actually changes.
private struct PlozziOSPlaybackOptionsMenu: View, Equatable {
    let audioOptions: [PlayerTrackOption]
    let subtitleOptions: [PlayerTrackOption]
    let canSearchRemoteSubtitles: Bool
    let supportsPlaybackSpeed: Bool
    let supportsSync: Bool
    let supportsDialogEnhance: Bool
    let dialogEnhanceEnabled: Bool
    let onSelectAudio: (PlayerTrackOption.ID) -> Void
    let onSetDialogEnhance: (Bool) -> Void
    let onShowSubtitles: () -> Void
    let onShowSpeed: () -> Void
    let onShowSync: () -> Void

    /// Compares the VALUES only. The transport's body re-evaluates on every
    /// playback-clock tick (roughly ten a second), which rebuilds this struct with
    /// freshly allocated closures; closures never compare equal, so without an
    /// explicit `==` SwiftUI has to assume the view changed and re-runs the `Menu`
    /// content closure. UIKit then rebuilds every row and submenu of the open
    /// menu, which is the repeated flashing. Splitting the view out is not enough
    /// on its own, the equality is what actually stops the work.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.audioOptions == rhs.audioOptions
            && lhs.subtitleOptions == rhs.subtitleOptions
            && lhs.canSearchRemoteSubtitles == rhs.canSearchRemoteSubtitles
            && lhs.supportsPlaybackSpeed == rhs.supportsPlaybackSpeed
            && lhs.supportsSync == rhs.supportsSync
            && lhs.supportsDialogEnhance == rhs.supportsDialogEnhance
            && lhs.dialogEnhanceEnabled == rhs.dialogEnhanceEnabled
    }

    var body: some View {
        Menu {
            if !audioOptions.isEmpty || supportsDialogEnhance {
                Menu("Audio") {
                    ForEach(audioOptions) { option in
                        Button {
                            onSelectAudio(option.id)
                        } label: {
                            if option.isSelected {
                                Label(option.title, systemImage: "checkmark")
                            } else {
                                Text(option.title)
                            }
                        }
                    }
                    if !audioOptions.isEmpty, supportsDialogEnhance {
                        Divider()
                    }
                    if supportsDialogEnhance {
                        Toggle(
                            "Dialog Enhance",
                            isOn: Binding(
                                get: { dialogEnhanceEnabled },
                                set: { onSetDialogEnhance($0) }
                            )
                        )
                    }
                }
            }

            if !subtitleOptions.isEmpty || canSearchRemoteSubtitles {
                Button("Subtitles", systemImage: "captions.bubble") {
                    onShowSubtitles()
                }
            }

            if supportsPlaybackSpeed {
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
                .playerTransportGlyph()
        }
        .accessibilityLabel("Audio, subtitles, and speed")
    }
}

private struct PlozziOSPlayerTransport: View {
    let viewModel: PlayerViewModel
    let displayedSeconds: TimeInterval
    let isScrubbing: Bool
    let scrubPreviewImage: CGImage?
    let showsScrubPreview: Bool
    let pictureInPictureAvailable: Bool
    let onTogglePictureInPicture: () -> Void
    let onScrubChanged: (TimeInterval) -> Void
    let onScrubEditingChanged: (Bool) -> Void
    let onSkipBackward: () -> Void
    let onPlayPause: () -> Void
    let onSkipForward: () -> Void
    let onShowInfo: () -> Void
    let onShowSpeed: () -> Void
    let onShowSubtitles: () -> Void
    let onShowSync: () -> Void
    let onInteraction: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            if isScrubbing, showsScrubPreview {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.black.opacity(0.72))

                    if let scrubPreviewImage {
                        Image(decorative: scrubPreviewImage, scale: 1)
                            .resizable()
                            .scaledToFit()
                    } else {
                        ProgressView()
                            .tint(.white)
                    }
                }
                .frame(width: 240, height: 135)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(.white.opacity(0.2), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.45), radius: 12, y: 4)
            }

            HStack {
                Text(playbackTime(displayedSeconds))
                Spacer()
                Text(verbatim: "-\(playbackTime(max(viewModel.controls.duration - displayedSeconds, 0)))")
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
                        .playerTransportGlyph()
                }
                .accessibilityLabel("Skip backward")

                Button(action: onPlayPause) {
                    Image(
                        systemName: viewModel.controls.intendsPause
                            ? "play.fill"
                            : "pause.fill"
                    )
                    .playerTransportGlyph(font: .title)
                }
                .accessibilityLabel(
                    viewModel.controls.intendsPause ? "Play" : "Pause"
                )

                Button(action: onSkipForward) {
                    Image(systemName: "goforward.\(viewModel.controls.skipForwardInterval.rawValue)")
                        .playerTransportGlyph()
                }
                .accessibilityLabel("Skip forward")

                Spacer(minLength: 8)

                playbackOptions

                if pictureInPictureAvailable {
                    Button(action: onTogglePictureInPicture) {
                        Image(systemName: "pip.enter")
                            .playerTransportGlyph()
                    }
                    .accessibilityLabel("Picture in Picture")
                }

                Button(action: onShowInfo) {
                    Image(systemName: "info.circle")
                        .playerTransportGlyph()
                }
                .accessibilityLabel("Playback information")
            }
            // Deliberately no .font / .foregroundStyle / .buttonStyle here. Those
            // travel through the environment into a Menu's POPUP content, not just
            // its label, so the menu's rows rendered white-on-light with the plain
            // button style until UIKit re-applied its own styling: the flash on
            // open. Each glyph now carries its own styling instead.
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    private var playbackOptions: some View {
        // Passes plain values, not the view model. `PlayerControlsModel` is
        // @Observable and the playback clock writes `currentSeconds` about ten
        // times a second, so a menu whose content closure touches
        // `viewModel.controls` is invalidated on every tick. UIKit then rebuilds
        // the open menu's rows underneath the user, which reads as the text
        // flashing. Snapshotting the inputs here means the menu only redraws when
        // something it actually shows has changed.
        PlozziOSPlaybackOptionsMenu(
            audioOptions: viewModel.controls.audioOptions,
            subtitleOptions: viewModel.controls.subtitleOptions,
            canSearchRemoteSubtitles: viewModel.controls.canSearchRemoteSubtitles,
            supportsPlaybackSpeed: viewModel.controls.engineCapabilities.contains(.playbackSpeed),
            supportsSync: supportsSync,
            supportsDialogEnhance: supportsDialogEnhance,
            dialogEnhanceEnabled: viewModel.controls.dialogEnhanceEnabled,
            onSelectAudio: { id in
                viewModel.selectAudioOption(id: id)
                onInteraction()
            },
            onSetDialogEnhance: { enabled in
                viewModel.setDialogEnhanceEnabled(enabled)
                onInteraction()
            },
            onShowSubtitles: onShowSubtitles,
            onShowSpeed: onShowSpeed,
            onShowSync: onShowSync
        )
        .equatable()
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

private struct PlozziOSSubtitleOptionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let viewModel: PlayerViewModel

    var body: some View {
        NavigationStack {
            Form {
                primaryTracks
                secondaryTracks
                appearance
                remoteSearch
            }
            .navigationTitle("Subtitles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }

    @ViewBuilder
    private var primaryTracks: some View {
        if !viewModel.controls.subtitleOptions.isEmpty {
            Section("Primary Track") {
                ForEach(viewModel.controls.subtitleOptions) { option in
                    Button {
                        viewModel.selectSubtitleOption(id: option.id)
                    } label: {
                        HStack {
                            Text(option.title)
                            Spacer()
                            if option.isSelected {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var secondaryTracks: some View {
        if let format = viewModel.controls.secondarySubtitleImagePrimaryFormat {
            Section("Second Track") {
                Text("Unavailable with \(format) image subtitles.")
                    .plozzForeground(.secondary)
            }
        } else if !viewModel.controls.secondarySubtitleOptions.isEmpty {
            Section("Second Track") {
                ForEach(viewModel.controls.secondarySubtitleOptions) { option in
                    Button {
                        viewModel.selectSecondarySubtitleOption(id: option.id)
                    } label: {
                        HStack {
                            Text(option.title)
                            Spacer()
                            if option.isSelected {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }

                if let statusText = secondaryStatusText {
                    Text(statusText)
                        .font(.caption)
                        .plozzForeground(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var appearance: some View {
        Section("Appearance") {
            if let format =
                viewModel.controls.secondarySubtitleImagePrimaryFormat {
                Label(
                    "\(format) subtitles are rendered as images and can’t be restyled.",
                    systemImage: "photo"
                )
                .plozzForeground(.secondary)
            } else {
                NavigationLink {
                    PlozziOSSubtitleAppearanceView(viewModel: viewModel)
                } label: {
                    LabeledContent(
                        "Style",
                        value: viewModel.controls.subtitleStyle.fontFamily.displayName
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var remoteSearch: some View {
        if viewModel.controls.canSearchRemoteSubtitles {
            Section("Find More") {
                switch viewModel.controls.subtitleDownloadState {
                case .idle:
                    searchButton
                case .searching:
                    HStack {
                        ProgressView()
                        Text("Searching…")
                    }
                case let .results(results):
                    ForEach(results) { subtitle in
                        Button {
                            viewModel.downloadAndLoadRemoteSubtitle(subtitle)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(subtitle.name)
                                Text(remoteSubtitleDetails(subtitle))
                                    .font(.caption)
                                    .plozzForeground(.secondary)
                            }
                        }
                    }
                    searchButton
                case .empty:
                    Text("No matching subtitles were found.")
                        .plozzForeground(.secondary)
                    searchButton
                case .downloading:
                    HStack {
                        ProgressView()
                        Text("Adding subtitle…")
                    }
                case .added:
                    Label("Subtitle added", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    searchButton
                case .failed:
                    Text("Subtitle search failed.")
                        .foregroundStyle(.red)
                    searchButton
                }
            }
        }
    }

    private var searchButton: some View {
        Button("Search for Subtitles", systemImage: "magnifyingglass") {
            viewModel.searchRemoteSubtitles()
        }
    }

    private var secondaryStatusText: LocalizedStringResource? {
        switch viewModel.controls.secondarySubtitleStatus {
        case .idle:
            nil
        case .loading:
            "Loading second subtitle…"
        case let .loaded(cueCount):
            cueCount == 0 ? "The selected track contains no cues." : nil
        case .unavailable:
            "The selected second subtitle could not be loaded."
        }
    }

    private func remoteSubtitleDetails(_ subtitle: RemoteSubtitle) -> String {
        [
            subtitle.language?.uppercased(),
            subtitle.format?.uppercased(),
            subtitle.providerName,
            subtitle.isForced ? "Forced" : nil,
            subtitle.isHearingImpaired ? "SDH" : nil
        ]
        .compactMap { $0 }
        .joined(separator: " • ")
    }
}

private struct PlozziOSSubtitleAppearanceView: View {
    let viewModel: PlayerViewModel

    var body: some View {
        Form {
            Section("Text") {
                NavigationLink {
                    PlozziOSSubtitleFontView(viewModel: viewModel)
                } label: {
                    LabeledContent(
                        "Font",
                        value: viewModel.controls.subtitleStyle.fontFamily.displayName
                    )
                }

                Picker(
                    "Weight",
                    selection: subtitleStyleBinding(viewModel, \.fontWeight)
                ) {
                    ForEach(
                        viewModel.controls.subtitleStyle.fontFamily.availableWeights,
                        id: \.self
                    ) {
                        Text($0.displayName).tag($0)
                    }
                }

                PlozziOSSubtitleSliderRow(
                    title: "Text Size",
                    value: subtitleStyleBinding(viewModel, \.fontScale),
                    range: 0.6...2.5,
                    step: 0.05,
                    formattedValue: {
                        "\((100 * $0).rounded().formatted())%"
                    }
                )
                PlozziOSSubtitleSliderRow(
                    title: "Position",
                    value: subtitleStyleBinding(viewModel, \.verticalPosition),
                    range: 0...0.9,
                    step: 0.01,
                    formattedValue: subtitlePositionLabel
                )
                PlozziOSSubtitleSliderRow(
                    title: "Horizontal Offset",
                    value: subtitleStyleBinding(viewModel, \.horizontalOffset),
                    range: -1...1,
                    step: 0.05,
                    formattedValue: {
                        let percent = Int(($0 * 100).rounded())
                        return percent == 0
                            ? "Center"
                            : "\(percent > 0 ? "+" : "")\(percent)%"
                    }
                )
                subtitleColorPicker(
                    "Text Color",
                    viewModel: viewModel,
                    keyPath: \.textColor,
                    options: SubtitleColor.presets
                )
                PlozziOSSubtitleSliderRow(
                    title: "Opacity",
                    value: subtitleStyleBinding(viewModel, \.opacity),
                    range: 0.2...1,
                    step: 0.05,
                    formattedValue: {
                        "\((100 * $0).rounded().formatted())%"
                    }
                )
                if viewModel.controls.subtitlesRenderHDR {
                    PlozziOSSubtitleSliderRow(
                        title: "HDR Brightness",
                        value: subtitleStyleBinding(
                            viewModel,
                            \.hdrLuminanceScale
                        ),
                        range: 0.2...1,
                        step: 0.05,
                        formattedValue: {
                            "\((100 * $0).rounded().formatted())%"
                        }
                    )
                }
            }

            Section("Details") {
                NavigationLink("Shadow & Outline") {
                    PlozziOSSubtitleShadowOutlineView(viewModel: viewModel)
                }
                NavigationLink {
                    PlozziOSSubtitleBackgroundView(viewModel: viewModel)
                } label: {
                    LabeledContent(
                        "Background",
                        value: viewModel.controls.subtitleStyle.background.isEnabled
                            ? "On"
                            : "Off"
                    )
                }
                NavigationLink {
                    PlozziOSSubtitleDualView(viewModel: viewModel)
                } label: {
                    LabeledContent(
                        "Dual Subtitles",
                        value: selectedSecondaryTrack(in: viewModel) == nil
                            ? "Off"
                            : "On"
                    )
                }
            }

            Section {
                Button("Reset to Default", role: .destructive) {
                    viewModel.applySubtitleStyle(.default)
                }
            }
        }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PlozziOSSubtitleFontView: View {
    let viewModel: PlayerViewModel

    var body: some View {
        List {
            ForEach(SubtitleFontFamily.allCases, id: \.self) { family in
                Button {
                    var style = viewModel.controls.subtitleStyle
                    style.fontFamily = family
                    style.fontWeight = style.fontWeight.snapped(
                        to: family.availableWeights
                    )
                    viewModel.applySubtitleStyle(style)
                } label: {
                    HStack {
                        Text(family.displayName)
                            .font(subtitlePreviewFont(for: family))
                        Spacer()
                        if family ==
                            viewModel.controls.subtitleStyle.fontFamily {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        }
        .navigationTitle("Font")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PlozziOSSubtitleShadowOutlineView: View {
    let viewModel: PlayerViewModel
    private let shadowStyles: [SubtitleEdgeStyle] = [
        .none, .dropShadow, .raised, .depressed
    ]

    var body: some View {
        Form {
            Section("Shadow") {
                Picker(
                    "Style",
                    selection: subtitleStyleBinding(viewModel, \.edge.style)
                ) {
                    ForEach(shadowStyles, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                if viewModel.controls.subtitleStyle.edge.style != .none {
                    subtitleColorPicker(
                        "Color",
                        viewModel: viewModel,
                        keyPath: \.edge.color,
                        options: SubtitleColor.presets
                    )
                    PlozziOSSubtitleSliderRow(
                        title: "Thickness",
                        value: subtitleStyleBinding(
                            viewModel,
                            \.edge.thickness
                        ),
                        range: 0...10,
                        step: 1,
                        formattedValue: { $0.rounded().formatted() }
                    )
                }
            }

            Section("Outline") {
                Toggle(
                    "Show Outline",
                    isOn: subtitleStyleBinding(
                        viewModel,
                        \.border.isEnabled
                    )
                )
                if viewModel.controls.subtitleStyle.border.isEnabled {
                    subtitleColorPicker(
                        "Color",
                        viewModel: viewModel,
                        keyPath: \.border.color,
                        options: SubtitleColor.presets
                    )
                    PlozziOSSubtitleSliderRow(
                        title: "Width",
                        value: subtitleStyleBinding(
                            viewModel,
                            \.border.width
                        ),
                        range: 0...10,
                        step: 0.5,
                        formattedValue: {
                            $0.formatted(
                                .number.precision(.fractionLength(0...1))
                            )
                        }
                    )
                }
            }
        }
        .navigationTitle("Shadow & Outline")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PlozziOSSubtitleBackgroundView: View {
    let viewModel: PlayerViewModel
    private let backgroundColors: [(name: String, color: SubtitleColor)] = [
        ("Black", .black),
        (
            "Dark Gray",
            SubtitleColor(red: 0.15, green: 0.15, blue: 0.15)
        ),
        ("White", .white)
    ]

    var body: some View {
        Form {
            Section {
                Toggle(
                    "Show Box",
                    isOn: subtitleStyleBinding(
                        viewModel,
                        \.background.isEnabled
                    )
                )
            }

            if viewModel.controls.subtitleStyle.background.isEnabled {
                Section("Box") {
                    subtitleColorPicker(
                        "Color",
                        viewModel: viewModel,
                        keyPath: \.background.color,
                        options: backgroundColors
                    )
                    PlozziOSSubtitleSliderRow(
                        title: "Opacity",
                        value: subtitleColorAlphaBinding(
                            viewModel,
                            \.background.color
                        ),
                        range: 0.05...1,
                        step: 0.05,
                        formattedValue: {
                            "\((100 * $0).rounded().formatted())%"
                        }
                    )
                    PlozziOSSubtitleSliderRow(
                        title: "Corner Radius",
                        value: subtitleStyleBinding(
                            viewModel,
                            \.background.cornerRadius
                        ),
                        range: 0...50,
                        step: 2,
                        formattedValue: {
                            "\($0.rounded().formatted()) pt"
                        }
                    )
                    PlozziOSSubtitleSliderRow(
                        title: "Horizontal Padding",
                        value: subtitleStyleBinding(
                            viewModel,
                            \.background.horizontalPadding
                        ),
                        range: 0...40,
                        step: 2,
                        formattedValue: {
                            "\($0.rounded().formatted()) pt"
                        }
                    )
                    PlozziOSSubtitleSliderRow(
                        title: "Vertical Padding",
                        value: subtitleStyleBinding(
                            viewModel,
                            \.background.verticalPadding
                        ),
                        range: 0...40,
                        step: 2,
                        formattedValue: {
                            "\($0.rounded().formatted()) pt"
                        }
                    )
                }
            }
        }
        .navigationTitle("Background")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PlozziOSSubtitleDualView: View {
    let viewModel: PlayerViewModel

    var body: some View {
        Form {
            Section("Second Track") {
                if let format =
                    viewModel.controls.secondarySubtitleImagePrimaryFormat {
                    Text("Unavailable with \(format) image subtitles.")
                        .plozzForeground(.secondary)
                } else if viewModel.controls.secondarySubtitleOptions.isEmpty {
                    Text("No additional text tracks are available.")
                        .plozzForeground(.secondary)
                } else {
                    ForEach(
                        viewModel.controls.secondarySubtitleOptions
                    ) { option in
                        Button {
                            viewModel.selectSecondarySubtitleOption(id: option.id)
                        } label: {
                            HStack {
                                Text(option.title)
                                Spacer()
                                if option.isSelected {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            }

            if selectedSecondaryTrack(in: viewModel) != nil,
               viewModel.controls.subtitleStyle.secondary != nil {
                Section("Layout") {
                    Picker(
                        "Placement",
                        selection: subtitleStyleBinding(
                            viewModel,
                            \.secondary!.placement
                        )
                    ) {
                        Text("Above").tag(
                            SubtitleStyle.Secondary.Placement.above
                        )
                        Text("Below").tag(
                            SubtitleStyle.Secondary.Placement.below
                        )
                    }
                    Toggle(
                        "Distinct Style",
                        isOn: subtitleStyleBinding(
                            viewModel,
                            \.secondary!.differentiate
                        )
                    )
                    if viewModel.controls.subtitleStyle.secondary?
                        .differentiate == true {
                        PlozziOSSubtitleSliderRow(
                            title: "Size",
                            value: subtitleStyleBinding(
                                viewModel,
                                \.secondary!.relativeScale
                            ),
                            range: 0.5...1,
                            step: 0.05,
                            formattedValue: {
                                "\((100 * $0).rounded().formatted())%"
                            }
                        )
                        subtitleColorPicker(
                            "Color",
                            viewModel: viewModel,
                            keyPath: \.secondary!.textColor,
                            options: SubtitleColor.presets
                        )
                    }
                    PlozziOSSubtitleSliderRow(
                        title: "Gap",
                        value: subtitleStyleBinding(
                            viewModel,
                            \.secondary!.gap
                        ),
                        range: 0...24,
                        step: 2,
                        formattedValue: {
                            "\($0.rounded().formatted()) pt"
                        }
                    )
                }
            }
        }
        .navigationTitle("Dual Subtitles")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PlozziOSSubtitleSliderRow: View {
    let title: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let formattedValue: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                Text(formattedValue(value))
                    .plozzForeground(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $value, in: range, step: step)
        }
    }
}

@MainActor
private func subtitleStyleBinding<Value>(
    _ viewModel: PlayerViewModel,
    _ keyPath: WritableKeyPath<SubtitleStyle, Value>
) -> Binding<Value> {
    Binding(
        get: {
            viewModel.controls.subtitleStyle[keyPath: keyPath]
        },
        set: { value in
            var style = viewModel.controls.subtitleStyle
            style[keyPath: keyPath] = value
            viewModel.applySubtitleStyle(style)
        }
    )
}

@MainActor
private func subtitleColorAlphaBinding(
    _ viewModel: PlayerViewModel,
    _ keyPath: WritableKeyPath<SubtitleStyle, SubtitleColor>
) -> Binding<Double> {
    Binding(
        get: {
            viewModel.controls.subtitleStyle[keyPath: keyPath].alpha
        },
        set: { alpha in
            var style = viewModel.controls.subtitleStyle
            style[keyPath: keyPath].alpha = alpha
            viewModel.applySubtitleStyle(style)
        }
    )
}

@MainActor
private func subtitleColorPicker(
    _ title: LocalizedStringKey,
    viewModel: PlayerViewModel,
    keyPath: WritableKeyPath<SubtitleStyle, SubtitleColor>,
    options: [(name: String, color: SubtitleColor)]
) -> some View {
    Picker(
        title,
        selection: Binding(
            get: {
                let current =
                    viewModel.controls.subtitleStyle[keyPath: keyPath]
                return options.first {
                    $0.color.red == current.red
                        && $0.color.green == current.green
                        && $0.color.blue == current.blue
                }?.color ?? current
            },
            set: { selected in
                var style = viewModel.controls.subtitleStyle
                let alpha = style[keyPath: keyPath].alpha
                var color = selected
                color.alpha = alpha
                style[keyPath: keyPath] = color
                viewModel.applySubtitleStyle(style)
            }
        )
    ) {
        ForEach(options, id: \.name) { option in
            Label {
                Text(option.name)
            } icon: {
                Circle()
                    .fill(
                        Color(
                            red: option.color.red,
                            green: option.color.green,
                            blue: option.color.blue
                        )
                    )
            }
            .tag(option.color)
        }
    }
}

private func subtitlePreviewFont(
    for family: SubtitleFontFamily
) -> Font {
    let size: CGFloat = family == .openDyslexic ? 17 : 22
    if family.usesRoundedDesign {
        return .system(size: size, design: .rounded)
    }
    if let stem = family.postScriptStem {
        return .custom("\(stem)-Regular", size: size)
    }
    return .system(size: size)
}

private func subtitlePositionLabel(_ value: Double) -> String {
    switch value {
    case ..<0.2: "Bottom"
    case 0.2..<0.65: "\((value * 100).rounded().formatted())%"
    default: "Top"
    }
}

@MainActor
private func selectedSecondaryTrack(
    in viewModel: PlayerViewModel
) -> PlayerTrackOption? {
    viewModel.controls.secondarySubtitleOptions.first {
        $0.isSelected && $0.id != PlayerTrackOption.offID
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
                                Text(verbatim: "\(rate.formatted(.number))×")
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
                        Text(verbatim: viewModel.controls.overview.overviewPlainText)
                            .plozzForeground(.secondary)
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
                        .plozzForeground(.secondary)
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
                        .plozzForeground(.secondary)
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
    let countdownRemaining: TimeInterval?
    let onPlay: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(info.eyebrow)
                    .font(.caption.weight(.semibold))
                    .plozzForeground(.secondary)
                Text(info.showName)
                    .font(.headline)
                    .lineLimit(1)
                if let metaLine = info.metaLine {
                    Text(metaLine)
                        .font(.caption)
                        .plozzForeground(.secondary)
                }
            }

            Button(action: onPlay) {
                HStack(spacing: 8) {
                    ZStack {
                        if let countdownRemaining, countdownRemaining > 0.05 {
                            Circle()
                                .stroke(.white.opacity(0.25), lineWidth: 3)
                            Circle()
                                .trim(
                                    from: 0,
                                    to: min(
                                        max(
                                            countdownRemaining
                                                / SkipIntrosMode.autoSkipDelay,
                                            0
                                        ),
                                        1
                                    )
                                )
                                .stroke(
                                    .white,
                                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                                )
                                .rotationEffect(.degrees(-90))
                            Text(Int(ceil(countdownRemaining)), format: .number)
                                .font(.caption2.monospacedDigit().bold())
                        } else {
                            Image(systemName: "play.fill")
                        }
                    }
                    .frame(width: 28, height: 28)

                    Text(countdownRemaining == nil ? "Play" : "Play Now")
                }
            }
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
