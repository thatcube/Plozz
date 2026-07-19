#if os(iOS)
import CoreGraphics
import CoreModels
import FeaturePlayback
import SwiftUI

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
                    isScrubbing: isScrubbing,
                    scrubPreviewImage: scrubPreviewCoordinator?.image,
                    showsScrubPreview: scrubPreviewCoordinator != nil,
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

    private func configureScrubPreview() {
        scrubPreviewCoordinator?.clear()
        scrubPreviewCoordinator = viewModel.makeScrubPreviewCoordinator()
        scrubPreviewCoordinator?.prefetch()
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
    let isScrubbing: Bool
    let scrubPreviewImage: CGImage?
    let showsScrubPreview: Bool
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

            if !viewModel.controls.subtitleOptions.isEmpty
                || viewModel.controls.canSearchRemoteSubtitles {
                Button("Subtitles", systemImage: "captions.bubble") {
                    onShowSubtitles()
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
                    .foregroundStyle(.secondary)
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
                        .foregroundStyle(.secondary)
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
                .foregroundStyle(.secondary)
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
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    searchButton
                case .empty:
                    Text("No matching subtitles were found.")
                        .foregroundStyle(.secondary)
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

    private var secondaryStatusText: String? {
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
                        .foregroundStyle(.secondary)
                } else if viewModel.controls.secondarySubtitleOptions.isEmpty {
                    Text("No additional text tracks are available.")
                        .foregroundStyle(.secondary)
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
                    .foregroundStyle(.secondary)
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
    let countdownRemaining: TimeInterval?
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
                            Text("\(Int(ceil(countdownRemaining)))")
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
