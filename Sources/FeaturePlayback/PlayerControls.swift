#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit
import CoreUI
import CoreModels

/// Lightweight value-type bag of options callbacks. Mirrors the tunable subset
/// of `PlayerActions` so the controls stay presentation-only.
@MainActor
struct PlayerOptionsActions {
    var togglePlayPause: () -> Void = {}
    var selectAudio: (Int) -> Void = { _ in }
    var selectSubtitle: (Int) -> Void = { _ in }
    var setPlaybackSpeed: (Double) -> Void = { _ in }
    var setAudioDelay: (TimeInterval) -> Void = { _ in }
    var setSubtitleDelay: (TimeInterval) -> Void = { _ in }
    var setDialogEnhance: (Bool) -> Void = { _ in }
    var playNextEpisode: () -> Void = {}
    var playPreviousEpisode: () -> Void = {}
    var restart: () -> Void = {}
}

/// The complete custom-player transport: a title bar, the scrub bar (with
/// buffered/played fill + floating trickplay thumbnail), and — directly beneath
/// the scrubber — a **focusable row of native tvOS buttons** (Audio & Subtitles ·
/// Speed · A/V Sync · Diagnostics), modelled on Netflix / the Apple
/// TV app.
///
///  * The button row is **visible whenever the transport is** so viewers can see
///    what's available; focus only drops into it on swipe-down / Down, and
///    returns to the scrub surface on Up / Menu.
///  * Selecting a category expands its options as a panel that floats just above
///    the scrubber, so the row stays put.
///  * Playback keeps running while adjusting (Infuse-style) so track/speed/sync
///    changes have instant feedback.
///  * Capability-driven — rows the active engine can't honour are hidden.
///
/// All Siri-Remote *scrubbing* input is handled in UIKit
/// (`PlayerInputViewController`); this view never takes focus while the player is
/// in its scrub state because the host disables its interaction then.
struct PlayerControls: View {
    let model: PlayerControlsModel
    let palette: ThemePalette
    let actions: PlayerOptionsActions
    /// Called when the viewer backs out of the button row (Up, or Menu with no
    /// panel open) so the container can return focus to the scrub surface.
    let onExitToSurface: () -> Void

    enum Category: Hashable {
        case subtitles, audio, speed, sync, info

        var title: String {
            switch self {
            case .subtitles: return "Subtitles"
            case .audio: return "Audio"
            case .speed: return "Speed"
            case .sync: return "A/V Sync"
            case .info: return "Info"
            }
        }

        var icon: String {
            switch self {
            case .subtitles: return "captions.bubble"
            case .audio: return "waveform"
            case .speed: return "speedometer"
            case .sync: return "slider.horizontal.below.square.and.square.filled"
            case .info: return "info.circle"
            }
        }
    }

    private enum FocusSlot: Hashable {
        case button(Category)
        case infoNext       // Info panel: Next Episode
        case infoPrev       // Info panel: Previous Episode
        case infoRestart    // Info panel: Restart
        case diagnostics
        case row(Int)
        case edit       // Subtitles header ✎ Edit (appearance) button
        case download   // Trailing "Search for subtitles…" row
        case subBack    // Back control inside a Subtitles sub-screen
    }

    /// Sub-screens of the Subtitles panel. `tracks` is the default list; the
    /// header ✎ Edit opens `style`, and the trailing row opens `download`. Menu
    /// backs a sub-screen out to `tracks` rather than closing the whole panel.
    private enum SubtitleScreen { case tracks, download, style }

    @State private var openPanel: Category?
    @State private var subtitleScreen: SubtitleScreen = .tracks
    @FocusState private var focus: FocusSlot?

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                topBar
                    .opacity(model.controlsVisible ? 1 : 0)
                Spacer(minLength: 0)
                bottomCluster
                    .opacity(model.controlsVisible ? 1 : 0)
            }
            .animation(.easeInOut(duration: 0.25), value: model.controlsVisible)
        }
        .ignoresSafeArea()
        .animation(.spring(response: 0.22, dampingFraction: 0.72), value: model.skipHintVisible)
        .onChange(of: model.controlBarVisible) { _, focused in
            openPanel = nil
            focus = focused ? initialFocus : nil
        }
        .onChange(of: openPanel) { _, panel in
            subtitleScreen = .tracks
            guard let panel else { return }
            if panel == .info {
                focus = model.hasNextEpisode ? .infoNext
                    : (model.hasPreviousEpisode ? .infoPrev : .infoRestart)
            } else {
                focus = .row(selectedRowIndex(for: panel))
            }
        }
        .onExitCommand { handleExit() }
        .onPlayPauseCommand { actions.togglePlayPause() }
        .onMoveCommand { direction in
            if direction == .up && openPanel == nil { onExitToSurface() }
        }
    }

    // MARK: Title

    private var topBar: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.title)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                if !model.subtitle.isEmpty {
                    Text(model.subtitle)
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            Spacer()
        }
        .padding(.horizontal, 60)
        .padding(.top, 50)
        .padding(.bottom, 80)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom)
        )
    }

    // MARK: Bottom cluster (scrubber + buttons)

    private var bottomCluster: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let openPanel {
                panelContainer(for: openPanel)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            scrubberRow
            buttonRow
        }
        .animation(.easeInOut(duration: 0.2), value: openPanel)
        .padding(.horizontal, 60)
        .padding(.top, 90)
        .padding(.bottom, 48)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
        )
    }

    private var scrubberRow: some View {
        VStack(spacing: 4) {
            ScrubBar(
                model: model,
                palette: palette,
                showThumbOverlay: openPanel == nil,
                leadingInset: 60,
                trailingInset: 60
            )
                .frame(height: 44)
                .frame(maxWidth: .infinity)
            // Remaining time under the bar, aligned to the right.
            Text("-" + Self.timeLabel(max(0, model.duration - model.displaySeconds)))
                .monospacedDigit()
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    // MARK: Button row

    private var buttonRow: some View {
        HStack(spacing: 20) {
            // Utility cluster (far left): media Info placeholder + Diagnostics.
            Button {
                toggle(.info)
            } label: {
                Label("Info", systemImage: "info.circle")
                    .labelStyle(.iconOnly)
            }
            .playerGlassButton(prominent: openPanel == .info)
            .focused($focus, equals: .button(.info))

            Button {
                model.diagnosticsEnabled.toggle()
            } label: {
                Label(
                    "Diagnostics",
                    systemImage: model.diagnosticsEnabled ? "waveform.circle.fill" : "waveform.circle"
                )
                .labelStyle(.iconOnly)
            }
            .playerGlassButton(prominent: model.diagnosticsEnabled)
            .focused($focus, equals: .diagnostics)

            Spacer(minLength: 20)

            // Track controls (far right), grouped: Speed · Audio · Subtitles.
            ForEach(availableCategories, id: \.self) { category in
                Button {
                    toggle(category)
                } label: {
                    Label(category.title, systemImage: category.icon)
                        .labelStyle(.iconOnly)
                }
                .playerGlassButton(prominent: openPanel == category)
                .focused($focus, equals: .button(category))
            }
        }
    }

    private func toggle(_ category: Category) {
        if openPanel == category {
            openPanel = nil
            focus = .button(category)
        } else {
            openPanel = category
        }
    }

    // MARK: Panels

    @ViewBuilder
    private func panelContainer(for category: Category) -> some View {
        if category == .info {
            infoPanel
                .colorScheme(.dark)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                panelHeader(for: category)
                Divider().background(.white.opacity(0.15))
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        switch category {
                        case .subtitles: subtitleBody
                        case .audio: audioPane
                        case .speed: speedPane
                        case .sync: syncPane
                        case .info: EmptyView()
                        }
                    }
                    .padding(.vertical, 10)
                }
                .frame(maxHeight: 440)
            }
            .frame(width: 520, alignment: .leading)
            .colorScheme(.dark)
            .modifier(PanelGlassBackground())
            // The track controls live on the right of the button row, so the panel
            // opens against the trailing edge above them rather than on the left.
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    // MARK: Info panel

    /// The "Series · S1E1 · 37 min" line under the title.
    private var episodeMetaLine: String {
        var parts: [String] = []
        if !model.subtitle.isEmpty { parts.append(model.subtitle) }
        if !model.infoRuntimeLabel.isEmpty { parts.append(model.infoRuntimeLabel) }
        return parts.joined(separator: " · ")
    }

    /// A wide now-playing card that slides into the controls area (video keeps
    /// playing full-frame behind it): thumbnail · title · meta line · overview ·
    /// badges, with Next/Previous Episode + Restart actions on the right.
    private var infoPanel: some View {
        // Concentric radii, matching the app's cards: the thumbnail's media radius
        // nested inside the card's glass radius (outer = inner + content padding),
        // so both corners share a centre.
        let thumbRadius = PlozzTheme.Metrics.mediumMediaCornerRadius
        let contentPad: CGFloat = 24
        let cardRadius = thumbRadius + contentPad

        return HStack(alignment: .top, spacing: 26) {
            infoThumbnail(cornerRadius: thumbRadius)

            VStack(alignment: .leading, spacing: 8) {
                Text(model.title.isEmpty ? "Now Playing" : model.title)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                if !episodeMetaLine.isEmpty {
                    Text(episodeMetaLine)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
                if !model.overview.isEmpty {
                    Text(model.overview)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
                if !model.infoBadges.isEmpty {
                    MediaBadgeRow(badges: model.infoBadges)
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 12) {
                if model.hasNextEpisode {
                    infoActionButton(title: "Next Episode", icon: "forward.end.fill", prominent: true, slot: .infoNext) {
                        actions.playNextEpisode()
                    }
                }
                if model.hasPreviousEpisode {
                    infoActionButton(title: "Previous", icon: "backward.end.fill", prominent: false, slot: .infoPrev) {
                        actions.playPreviousEpisode()
                    }
                }
                infoActionButton(title: "Restart", icon: "arrow.counterclockwise", prominent: false, slot: .infoRestart) {
                    actions.restart()
                    openPanel = nil
                    focus = .button(.info)
                }
            }
            .frame(width: 260)
        }
        .padding(contentPad)
        .frame(maxWidth: 1180, alignment: .leading)
        .modifier(PanelGlassBackground(cornerRadius: cardRadius))
    }

    private func infoThumbnail(cornerRadius: CGFloat) -> some View {
        Color.clear
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .frame(width: 300)
            .overlay {
                FallbackAsyncImage(urls: model.artworkURLs) {
                    Rectangle().fill(Color.white.opacity(0.08))
                        .overlay(
                            Image(systemName: "photo")
                                .font(.system(size: 34, weight: .regular))
                                .foregroundStyle(.white.opacity(0.28))
                        )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .plozzMediaEdge(cornerRadius: cornerRadius)
    }

    private func infoActionButton(
        title: String,
        icon: String,
        prominent: Bool,
        slot: FocusSlot,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.headline)
                .frame(maxWidth: .infinity)
        }
        .playerGlassButton(prominent: prominent)
        .focused($focus, equals: slot)
    }

    /// Header of the floating panel: the screen title on the left, and — on the
    /// Subtitles track list only — the ✎ Edit (appearance) button on the right.
    @ViewBuilder
    private func panelHeader(for category: Category) -> some View {
        HStack(spacing: 12) {
            Text(headerTitle(for: category))
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            Spacer(minLength: 12)
            if category == .subtitles && subtitleScreen == .tracks {
                Button {
                    openSubtitleScreen(.style)
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .playerGlassButton(prominent: false)
                .focused($focus, equals: .edit)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 12)
    }

    private func headerTitle(for category: Category) -> String {
        guard category == .subtitles else { return category.title }
        switch subtitleScreen {
        case .tracks: return "Subtitles"
        case .download: return "Download Subtitles"
        case .style: return "Subtitle Style"
        }
    }

    /// The Subtitles panel is a small master flow: the track list (default), a
    /// Download screen (from the trailing row) and a Style screen (from ✎ Edit).
    @ViewBuilder
    private var subtitleBody: some View {
        switch subtitleScreen {
        case .tracks: subtitlePane
        case .download: subtitleDownloadStub
        case .style: subtitleStyleStub
        }
    }

    /// The Subtitles track list: one full-width column of selectable tracks
    /// (incl. "Off"), then a trailing "Search for subtitles…" row. Full width so
    /// a rich label ("Spanish (SDH, PGS)") never truncates.
    @ViewBuilder
    private var subtitlePane: some View {
        VStack(alignment: .leading, spacing: 2) {
            let rows = subtitleRows
            if rows.isEmpty {
                emptyRow("No subtitles")
            } else {
                trackRowStack(rows)
            }
            Divider()
                .background(.white.opacity(0.12))
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            downloadEntryRow
        }
        .padding(.horizontal, 14)
    }

    /// "Looked through them all, found nothing → get more." Kept at the END of
    /// the list so it surfaces exactly when it's needed (few / no tracks) and
    /// stays out of the way when there are many.
    private var downloadEntryRow: some View {
        Button {
            openSubtitleScreen(.download)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle").font(.body)
                Text("Search for subtitles…").font(.body).lineLimit(1)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlayerMenuRowButtonStyle())
        .focusEffectDisabled()
        .focused($focus, equals: .download)
    }

    // MARK: Subtitles sub-screens (Download / Style) — stubs for now

    private var subtitleDownloadStub: some View {
        subScreenStub(message: "Search the server's providers for a subtitle in your language and load it right here.")
    }

    private var subtitleStyleStub: some View {
        subScreenStub(message: "Adjust size, position, colour, background and outline — previewed live over the video.")
    }

    private func subScreenStub(message: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(message)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
            Text("Coming soon")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.4))
            Button {
                openSubtitleScreen(.tracks)
            } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .playerGlassButton(prominent: false)
            .focused($focus, equals: .subBack)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func openSubtitleScreen(_ screen: SubtitleScreen) {
        subtitleScreen = screen
        switch screen {
        case .tracks: focus = .row(selectedRowIndex(for: .subtitles))
        case .download, .style: focus = .subBack
        }
    }

    /// The Audio menu: one full-width column of selectable tracks plus the
    /// Dialog Enhance toggle when the engine supports it.
    @ViewBuilder
    private var audioPane: some View {
        let rows = audioRows
        if rows.isEmpty {
            emptyRow("No alternate audio")
        } else {
            trackRowStack(rows).padding(.horizontal, 14)
        }
    }

    @ViewBuilder
    private func trackRowStack(_ rows: [TrackRow]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(rows) { row in
                if row.isToggle {
                    compactToggleRow(row)
                } else {
                    compactSelectableRow(row)
                }
            }
        }
    }

    private func compactSelectableRow(_ row: TrackRow) -> some View {
        Button(action: row.action) {
            HStack(spacing: 10) {
                Text(row.title)
                    .font(.body)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if row.isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .playerMenuRowMark(isSelected: true, accent: palette.accent)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlayerMenuRowButtonStyle())
        .focusEffectDisabled()
        .focused($focus, equals: .row(row.id))
    }

    private func compactToggleRow(_ row: TrackRow) -> some View {
        Button(action: row.action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title).font(.body.weight(.medium)).lineLimit(1)
                    if !row.subtitle.isEmpty {
                        Text(row.subtitle)
                            .font(.caption2)
                            .playerMenuRowSecondary()
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: row.isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.body)
                    .playerMenuRowMark(isSelected: row.isSelected, accent: palette.accent)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlayerMenuRowButtonStyle())
        .focusEffectDisabled()
        .focused($focus, equals: .row(row.id))
    }

    @ViewBuilder
    private var speedPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Fine control: − {value}× + in 0.05 steps (0.25×–2×). Drives the same
            // model.playbackSpeed as the presets below, so they stay in sync.
            HStack {
                Spacer(minLength: 0)
                SettingsStepper(
                    options: Array(0..<Self.speedGridCount),
                    selection: Binding(
                        get: { Self.nearestSpeedIndex(model.playbackSpeed) },
                        set: { actions.setPlaybackSpeed(Self.speedGridValue($0)) }
                    ),
                    title: { Self.speedLabel(Self.speedGridValue($0)) }
                )
                Spacer(minLength: 0)
            }
            .padding(.vertical, 14)

            Divider()
                .background(.white.opacity(0.12))
                .padding(.horizontal, 8)
                .padding(.bottom, 4)

            // Quick presets.
            ForEach(Array(Self.speedPresets.enumerated()), id: \.offset) { index, speed in
                selectableRow(
                    title: Self.speedLabel(speed),
                    isSelected: abs(model.playbackSpeed - speed) < 0.001,
                    index: index
                ) {
                    actions.setPlaybackSpeed(speed)
                }
            }
        }
    }

    @ViewBuilder
    private var syncPane: some View {
        VStack(alignment: .leading, spacing: 22) {
            if model.engineCapabilities.contains(.audioDelay) {
                delayRow(
                    title: "Audio Delay",
                    value: model.audioDelaySeconds,
                    firstSlot: 0,
                    onAdjust: { actions.setAudioDelay(model.audioDelaySeconds + $0) },
                    onReset: { actions.setAudioDelay(0) }
                )
            }
            if model.engineCapabilities.contains(.subtitleDelay) {
                delayRow(
                    title: "Subtitle Delay",
                    value: model.subtitleDelaySeconds,
                    firstSlot: 10,
                    onAdjust: { actions.setSubtitleDelay(model.subtitleDelaySeconds + $0) },
                    onReset: { actions.setSubtitleDelay(0) }
                )
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
    }

    // MARK: Rows

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white.opacity(0.5))
            .padding(.horizontal, 28)
            .padding(.top, 16)
            .padding(.bottom, 6)
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(.title3)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
    }

    private func selectableRow(
        title: String,
        isSelected: Bool,
        index: Int,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(title).font(.body).lineLimit(1)
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .playerMenuRowMark(isSelected: true, accent: palette.accent)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlayerMenuRowButtonStyle())
        .focusEffectDisabled()
        .focused($focus, equals: .row(index))
    }

    private func toggleRow(
        title: String,
        subtitle: String,
        isOn: Bool,
        index: Int,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.title3.weight(.medium))
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.footnote).playerMenuRowSecondary()
                    }
                }
                Spacer()
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .playerMenuRowMark(isSelected: isOn, accent: palette.accent)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlayerMenuRowButtonStyle())
        .focusEffectDisabled()
        .focused($focus, equals: .row(index))
    }

    private func delayRow(
        title: String,
        value: TimeInterval,
        firstSlot: Int,
        onAdjust: @escaping (TimeInterval) -> Void,
        onReset: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.title3.weight(.medium))
                Spacer()
                Text(Self.delayLabel(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                stepButton("−500 ms", slot: firstSlot + 0) { onAdjust(-0.5) }
                stepButton("−50 ms", slot: firstSlot + 1) { onAdjust(-0.05) }
                stepButton("Reset", slot: firstSlot + 2, action: onReset)
                stepButton("+50 ms", slot: firstSlot + 3) { onAdjust(0.05) }
                stepButton("+500 ms", slot: firstSlot + 4) { onAdjust(0.5) }
            }
        }
    }

    private func stepButton(_ title: String, slot: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.callout.weight(.medium))
        }
        .focused($focus, equals: .row(slot))
    }

    // MARK: Model helpers

    /// Track controls, left→right: Speed · Audio · **Subtitles** (Subtitles at the
    /// far-right edge), rendered on the right of the button row opposite the
    /// left-hand utility cluster (Info · Diagnostics).
    ///
    /// A/V Sync is intentionally omitted for now — the standalone button was
    /// removed. `Category.sync` + `syncPane` are kept so it can be restored later.
    private var availableCategories: [Category] {
        var result: [Category] = []
        if model.engineCapabilities.contains(.playbackSpeed) {
            result.append(.speed)
        }
        if model.hasSelectableAudio
            || model.engineCapabilities.contains(.dialogEnhance) {
            result.append(.audio)
        }
        if model.hasSelectableSubtitles {
            result.append(.subtitles)
        }
        return result
    }

    /// Focus target when the bar first takes focus: Subtitles (the most-used
    /// control) when present, otherwise the first category, otherwise the
    /// always-present Diagnostics button.
    private var initialFocus: FocusSlot {
        if availableCategories.contains(.subtitles) { return .button(.subtitles) }
        if let first = availableCategories.first { return .button(first) }
        return .diagnostics
    }

    private struct TrackRow: Identifiable {
        let id: Int
        let header: String?
        let title: String
        let subtitle: String
        let isSelected: Bool
        let isToggle: Bool
        let action: () -> Void
    }

    /// Subtitle menu rows (one full-width column, including "Off"). Indexed from
    /// 0 in their own focus-slot space — safe because only one panel is open at a
    /// time, so audio and subtitle `.row` ids never coexist.
    private var subtitleRows: [TrackRow] {
        guard model.hasSelectableSubtitles else { return [] }
        return model.subtitleOptions.enumerated().map { index, option in
            TrackRow(
                id: index,
                header: nil,
                title: option.title,
                subtitle: "",
                isSelected: option.isSelected,
                isToggle: false,
                action: { actions.selectSubtitle(option.id) }
            )
        }
    }

    /// Audio menu rows: selectable tracks followed by the Dialog Enhance toggle
    /// when supported. Indexed from 0 in their own focus-slot space.
    private var audioRows: [TrackRow] {
        var rows: [TrackRow] = []
        var index = 0
        if model.hasSelectableAudio {
            for option in model.audioOptions {
                rows.append(TrackRow(
                    id: index,
                    header: nil,
                    title: option.title,
                    subtitle: "",
                    isSelected: option.isSelected,
                    isToggle: false,
                    action: { actions.selectAudio(option.id) }
                ))
                index += 1
            }
        }
        if model.engineCapabilities.contains(.dialogEnhance) {
            rows.append(TrackRow(
                id: index,
                header: nil,
                title: "Dialog Enhance",
                subtitle: "Boost speech clarity in loud mixes",
                isSelected: model.dialogEnhanceEnabled,
                isToggle: true,
                action: { actions.setDialogEnhance(!model.dialogEnhanceEnabled) }
            ))
            index += 1
        }
        return rows
    }

    private func selectedRowIndex(for category: Category) -> Int {
        switch category {
        case .subtitles:
            // Open focused on the active subtitle (incl. "Off"), else the top row.
            return subtitleRows.first(where: { $0.isSelected })?.id ?? 0
        case .audio:
            return audioRows.first(where: { $0.isSelected })?.id ?? 0
        case .speed:
            return Self.speedPresets.firstIndex(where: { abs(model.playbackSpeed - $0) < 0.001 }) ?? 0
        case .sync:
            return 0
        case .info:
            return 0
        }
    }

    private func handleExit() {
        // Back out of a Subtitles sub-screen to the track list first; only then
        // does Menu close the whole panel.
        if openPanel == .subtitles && subtitleScreen != .tracks {
            openSubtitleScreen(.tracks)
            return
        }
        if let category = openPanel {
            openPanel = nil
            focus = .button(category)
        } else {
            onExitToSurface()
        }
    }

    // MARK: Formatting

    static let speedPresets: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    // Custom-speed grid for the − / + stepper: 0.25×…2.0× in 0.05 steps. Modelled
    // as integer indices so the stepper matches exactly (no Double == fuzziness);
    // the Double rate is derived on the way in (nearest index) and out (grid value).
    static let speedStepMin = 0.25
    static let speedStepMax = 2.0
    static let speedStep = 0.05
    static var speedGridCount: Int {
        Int(((speedStepMax - speedStepMin) / speedStep).rounded()) + 1
    }
    static func speedGridValue(_ index: Int) -> Double {
        ((speedStepMin + Double(index) * speedStep) * 100).rounded() / 100
    }
    static func nearestSpeedIndex(_ speed: Double) -> Int {
        let raw = ((speed - speedStepMin) / speedStep).rounded()
        return Int(min(max(raw, 0), Double(speedGridCount - 1)))
    }

    static func speedLabel(_ speed: Double) -> String {
        if abs(speed - speed.rounded()) < 0.001 {
            return String(format: "%.0f×", speed)
        }
        return String(format: "%.2f×", speed).replacingOccurrences(of: "0×", with: "×")
    }

    static func delayLabel(_ seconds: TimeInterval) -> String {
        let ms = Int((seconds * 1000).rounded())
        if ms == 0 { return "0 ms" }
        return ms > 0 ? "+\(ms) ms" : "\(ms) ms"
    }

    static func timeLabel(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}

/// The scrub track: buffered + played fill, a knob, and a floating trickplay
/// thumbnail positioned over the scrub head while scrubbing.
private struct ScrubBar: View {
    let model: PlayerControlsModel
    let palette: ThemePalette
    /// Whether to float the thumb overlay (current time + skip hint + remaining)
    /// above the scrub head. Suppressed while a category panel is open so it
    /// can't collide with the panel.
    var showThumbOverlay: Bool = true
    /// Horizontal distance from the scrub track's leading/trailing edge out to the
    /// screen edge, so the trickplay thumbnail can extend past the track (but not
    /// off-screen).
    var leadingInset: CGFloat = 0
    var trailingInset: CGFloat = 0

    /// Subtle "pressed-down" scale applied to the ±10s glyph on each skip press,
    /// so rapid spamming reads as a held button rather than a flashing re-pop.
    @State private var skipPressed = false
    @State private var skipPressTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let knobX = width * CGFloat(model.progressFraction)
            // The bar is "focused" whenever the scrub surface owns focus — the
            // controls are up and focus hasn't dropped to the button row below
            // (scrubbing counts as focused). Focused, the bar is full height,
            // the played fill is bright and the playhead is a rounded pill. Once
            // focus moves to the buttons the bar slims by 8pt, the fill fades and
            // the playhead squares off flush into the track.
            let focused = model.controlsVisible && !model.controlBarVisible
            let barHeight: CGFloat = focused ? 20 : 12
            let knobWidth: CGFloat = focused ? 8 : 4
            let knobHeight: CGFloat = focused ? (model.isScrubbing ? 40 : 32) : barHeight

            ZStack(alignment: .leading) {
                glassTrack(height: barHeight)
                Capsule()
                    .fill(.white.opacity(0.14))
                    .frame(width: width * CGFloat(model.bufferedFraction), height: barHeight)
                UnevenRoundedRectangle(
                    topLeadingRadius: 10,
                    bottomLeadingRadius: 10,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 0,
                    style: .continuous
                )
                    .fill(.white.opacity(focused ? 0.62 : 0.32))
                    .frame(width: knobX, height: barHeight)
                RoundedRectangle(cornerRadius: focused ? knobWidth / 2 : 0, style: .continuous)
                    .fill(.white)
                    .frame(width: knobWidth, height: knobHeight)
                    .offset(x: knobX - knobWidth / 2)
                    .shadow(radius: 4)

                if model.isScrubbing && model.hasPreviewFrame {
                    thumbnailPreview(width: width, knobX: knobX)
                        .transition(.thumbnailDismiss)
                }
                if showThumbOverlay || model.isScrubbing {
                    thumbOverlay(width: width, knobX: knobX)
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .animation(.easeOut(duration: 0.12), value: model.isScrubbing)
            .animation(.easeOut(duration: 0.2), value: model.controlBarVisible)
            .animation(.easeOut(duration: 0.2), value: model.controlsVisible)
            .onChange(of: model.skipHintToken) { _, _ in pulseSkipPress() }
            .onChange(of: model.skipHintVisible) { _, visible in
                if !visible { skipPressed = false }
            }
        }
    }

    /// The base scrub track rendered as Liquid Glass on tvOS 26+, with a
    /// translucent-fill fallback on older systems.
    @ViewBuilder
    private func glassTrack(height: CGFloat) -> some View {
        if #available(tvOS 26.0, *) {
            Capsule()
                .fill(.clear)
                .frame(height: height)
                .glassEffect(.regular, in: Capsule())
        } else {
            Capsule()
                .fill(.white.opacity(0.22))
                .frame(height: height)
        }
    }

    /// Dips the glyph on a press, then springs it back ~90 ms after the *last*
    /// press — so while spamming it stays gently pressed and only releases once
    /// the user stops.
    private func pulseSkipPress() {
        skipPressTask?.cancel()
        withAnimation(.easeOut(duration: 0.06)) { skipPressed = true }
        skipPressTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 90_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { skipPressed = false }
        }
    }

    /// Vertical anchor (relative to the scrub track) for the time + glyph row.
    /// Kept constant across scrubbing / non-scrubbing so the time never jumps;
    /// the trickplay thumbnail floats above this line.
    static let timeRowY: CGFloat = -28

    /// Floated just above the scrub head (the focus indicator) and tracking it,
    /// Apple-TV style. The current time is pinned dead-centre on the thumb and
    /// never moves; the flanking glyphs hang off its left/right edges as overlays
    /// so they can't shift it. A backward skip (and, if the seek is still
    /// resolving, the loading spinner) sits to the left; a forward skip, the
    /// spinner for a forward seek / plain scrub, and the circular pause glyph sit
    /// to the right. Clamped so the time never runs off either edge.
    @ViewBuilder
    private func thumbOverlay(width: CGFloat, knobX: CGFloat) -> some View {
        // Left edge of text aligns with left edge of the scrub track (x=0).
        // ~30 approximates half the time label width at .callout size.
        let leftMargin: CGFloat = 30
        let rightMargin: CGFloat = 120
        let cx = min(max(leftMargin, knobX), max(leftMargin, width - rightMargin))
        Text(PlayerControls.timeLabel(model.displaySeconds))
            .monospacedDigit()
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .fixedSize()
            .shadow(radius: 3)
            .overlay(alignment: .leading) {
                leftSlot.frame(width: 44, height: 44).offset(x: -50)
            }
            .overlay(alignment: .trailing) {
                rightSlot.frame(width: 44, height: 44).offset(x: 50)
            }
            .position(x: cx, y: Self.timeRowY)
    }

    /// Left of the current time: the backward-skip glyph after a backward skip,
    /// replaced by the loading spinner if a backward seek is still resolving.
    @ViewBuilder private var leftSlot: some View {
        if model.skipHintVisible && !model.skipHintForward {
            skipGlyph(forward: false)
        } else if model.isSeeking && model.seekIndicatorOnLeft {
            spinner
        }
    }

    /// Right of the current time: the forward-skip glyph after a forward skip;
    /// otherwise the spinner for a forward seek / plain scrub; otherwise the
    /// circular pause glyph while paused. All share this one slot.
    @ViewBuilder private var rightSlot: some View {
        if model.skipHintVisible && model.skipHintForward {
            skipGlyph(forward: true)
        } else if model.isSeeking && !model.seekIndicatorOnLeft {
            spinner
        } else if model.isPaused {
            Image(systemName: "pause.circle.fill")
                .font(.system(size: 30))
                .foregroundStyle(.white)
                .shadow(radius: 3)
        }
    }

    /// Compact skip glyph whose number matches the per-profile interval. It
    /// persists for the whole skip burst (no per-press teardown), and a subtle
    /// scale dip gives "pressed" feedback on each press.
    private func skipGlyph(forward: Bool) -> some View {
        let symbol = forward
            ? model.skipForwardInterval.forwardSymbol
            : model.skipBackwardInterval.backwardSymbol
        return Image(systemName: symbol)
            .font(.system(size: 28, weight: .semibold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
            .scaleEffect(skipPressed ? 0.9 : 1.0)
            .transition(.scale(scale: 0.5).combined(with: .opacity))
    }

    private var spinner: some View {
        ProgressView()
            .tint(.white)
            .controlSize(.small)
    }

    @ViewBuilder
    private func thumbnailPreview(width: CGFloat, knobX: CGFloat) -> some View {
        if let image = model.previewImage {
            let thumbWidth: CGFloat = 420
            let aspect = previewAspect
            let thumbHeight = thumbWidth / aspect
            let corner: CGFloat = 18
            let border: CGFloat = 12
            // Account for glass border so visual left edge sits at x=0 (track edge).
            let visualWidth = thumbWidth + 2 * border
            let minX = visualWidth / 2
            let edgeMargin: CGFloat = 16
            let maxX = width + trailingInset - visualWidth / 2 - edgeMargin
            let clampedX = min(max(minX, knobX), max(minX, maxX))

            let content = Image(decorative: image, scale: 1, orientation: .up)
                .resizable()
                .interpolation(.medium)
                .aspectRatio(contentMode: .fill)
                .frame(width: thumbWidth, height: thumbHeight)
                .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))

            Group {
                if #available(tvOS 26.0, *) {
                    content
                        .padding(border)
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: corner + border, style: .continuous))
                } else {
                    content
                        .overlay(
                            RoundedRectangle(cornerRadius: corner, style: .continuous)
                                .stroke(.white.opacity(0.85), lineWidth: border)
                        )
                }
            }
            .position(x: clampedX, y: Self.timeRowY - 46 - thumbHeight / 2)
        }
    }

    private var previewAspect: CGFloat {
        guard let image = model.previewImage, image.height > 0 else { return 16.0 / 9.0 }
        return CGFloat(image.width) / CGFloat(image.height)
    }
}

/// Drives the trickplay thumbnail's dismissal: it appears instantly (identity
/// insertion) and, on removal, quickly fades while blurring, scaling down a
/// touch, and drifting slightly downward.
private struct ThumbnailTransitionModifier: ViewModifier {
    /// 0 = fully visible, 1 = fully dismissed.
    var progress: CGFloat

    func body(content: Content) -> some View {
        content
            .blur(radius: 9 * progress)
            .offset(y: 13 * progress)
            .opacity(Double(max(0, 1 - progress * 4.5)))
    }
}

private extension AnyTransition {
    static var thumbnailDismiss: AnyTransition {
        .asymmetric(
            insertion: .identity,
            removal: .modifier(
                active: ThumbnailTransitionModifier(progress: 1),
                identity: ThumbnailTransitionModifier(progress: 0)
            )
        )
    }
}

private extension View {
    /// Applies the system Liquid Glass button style (tvOS 26+), falling back to
    /// the bordered styles on older systems. `prominent` highlights the active
    /// category / enabled toggle.
    @ViewBuilder
    func playerGlassButton(prominent: Bool) -> some View {
        if #available(tvOS 26.0, *) {
            if prominent {
                buttonStyle(.glassProminent)
            } else {
                buttonStyle(.glass)
            }
        } else {
            if prominent {
                buttonStyle(.borderedProminent)
            } else {
                buttonStyle(.bordered)
            }
        }
    }
}

/// The floating panel's translucent backing. Native **Liquid Glass** on tvOS
/// 26+, falling back to a cheap solid translucent fill below that (and honouring
/// the perf intent on older devices).
///
/// Still **no `.shadow`** — a soft drop shadow was the original frame-drop
/// culprit over Dolby Vision (a per-frame offscreen blur recomposited on the
/// moving HDR signal). A 1px stroke gives edge separation instead. The glass is
/// a *bounded* backdrop sample (the panel is only 760pt wide), so keep an eye on
/// the diagnostics FPS over DV content and fall back to the solid fill if it
/// ever stutters.
private struct PanelGlassBackground: ViewModifier {
    var cornerRadius: CGFloat = 24
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous) }

    func body(content: Content) -> some View {
        if #available(tvOS 26.0, *) {
            content
                .glassEffect(.regular, in: shape)
                .overlay(shape.stroke(.white.opacity(0.12), lineWidth: 1))
        } else {
            content
                .background(Color.black.opacity(0.8))
                .clipShape(shape)
                .overlay(shape.stroke(.white.opacity(0.14), lineWidth: 1))
        }
    }
}
#endif
