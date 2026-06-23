#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit
import CoreUI

/// Lightweight value-type bag of options callbacks. Mirrors the tunable subset
/// of `PlayerActions` so the controls stay presentation-only.
@MainActor
struct PlayerOptionsActions {
    var selectAudio: (Int) -> Void = { _ in }
    var selectSubtitle: (Int) -> Void = { _ in }
    var setPlaybackSpeed: (Double) -> Void = { _ in }
    var setAudioDelay: (TimeInterval) -> Void = { _ in }
    var setSubtitleDelay: (TimeInterval) -> Void = { _ in }
    var setDialogEnhance: (Bool) -> Void = { _ in }
}

/// The complete custom-player transport: a title bar, the scrub bar (with
/// buffered/played fill + floating trickplay thumbnail), and — directly beneath
/// the scrubber — a **focusable row of native tvOS buttons** (Audio & Subtitles ·
/// Speed · A/V Sync · Diagnostics), modelled on Netflix / the Apple TV app.
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
        case audioSubtitles, speed, sync

        var title: String {
            switch self {
            case .audioSubtitles: return "Audio & Subtitles"
            case .speed: return "Speed"
            case .sync: return "A/V Sync"
            }
        }

        var icon: String {
            switch self {
            case .audioSubtitles: return "captions.bubble"
            case .speed: return "speedometer"
            case .sync: return "slider.horizontal.below.square.and.square.filled"
            }
        }
    }

    private enum FocusSlot: Hashable {
        case button(Category)
        case diagnostics
        case row(Int)
    }

    @State private var openPanel: Category?
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
        .animation(.spring(response: 0.22, dampingFraction: 0.72), value: model.skipHintToken)
        .onChange(of: model.controlBarVisible) { _, focused in
            openPanel = nil
            focus = focused ? initialFocus : nil
        }
        .onChange(of: openPanel) { _, panel in
            if let panel { focus = .row(selectedRowIndex(for: panel)) }
        }
        .onExitCommand { handleExit() }
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
        HStack(spacing: 22) {
            ScrubBar(model: model, palette: palette, showTimeBubble: openPanel == nil)
                .frame(height: 26)
                .frame(maxWidth: .infinity)
            // Apple-TV-style status cluster pinned to the right of the bar:
            // the transient ±10s skip hint, then the remaining time, then a
            // small spinner (while seeking) or pause glyph. Fixed width so the
            // scrub track never resizes as the contents change.
            HStack(spacing: 12) {
                skipHintInline
                    .frame(width: 46)
                Text("-" + Self.timeLabel(max(0, model.duration - model.displaySeconds)))
                    .monospacedDigit()
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.85))
                transportStatus
            }
            .frame(width: 250, alignment: .leading)
        }
    }

    @ViewBuilder private var transportStatus: some View {
        if model.isSeeking {
            ProgressView()
                .tint(.white)
                .controlSize(.small)
        } else if model.isPaused {
            Image(systemName: "pause.fill")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.85))
        }
    }

    // MARK: Button row

    private var buttonRow: some View {
        HStack(spacing: 20) {
            ForEach(availableCategories, id: \.self) { category in
                Button {
                    toggle(category)
                } label: {
                    Label(category.title, systemImage: category.icon)
                        .font(.headline)
                }
                .playerGlassButton(prominent: openPanel == category)
                .focused($focus, equals: .button(category))
            }

            Button {
                model.diagnosticsEnabled.toggle()
            } label: {
                Label(
                    "Diagnostics",
                    systemImage: model.diagnosticsEnabled ? "waveform.circle.fill" : "waveform.circle"
                )
                .font(.headline)
            }
            .playerGlassButton(prominent: model.diagnosticsEnabled)
            .focused($focus, equals: .diagnostics)
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

    // MARK: Skip hint

    /// A compact, transient ±10s indicator that lives in the status cluster to
    /// the right of the scrub bar (Apple-TV style). The fixed-width slot keeps
    /// the bar from shifting whether or not it's showing. `.id(token)` replays
    /// the snappy spring pop-in on every skip, even rapid repeats.
    @ViewBuilder private var skipHintInline: some View {
        if model.skipHintVisible {
            Image(systemName: model.skipHintForward ? "goforward.10" : "gobackward.10")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .padding(8)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.14), lineWidth: 1))
                .shadow(radius: 6)
                .id(model.skipHintToken)
                .transition(.scale(scale: 0.5).combined(with: .opacity))
        }
    }

    // MARK: Panels

    @ViewBuilder
    private func panelContainer(for category: Category) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(category.title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 28)
                .padding(.top, 22)
                .padding(.bottom, 12)
            Divider().background(.white.opacity(0.15))
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch category {
                    case .audioSubtitles: audioSubtitlesPane
                    case .speed: speedPane
                    case .sync: syncPane
                    }
                }
                .padding(.vertical, 10)
            }
            .frame(maxHeight: 440)
        }
        .frame(width: 760, alignment: .leading)
        .background(.ultraThinMaterial)
        .colorScheme(.dark)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(radius: 24)
    }

    @ViewBuilder
    private var audioSubtitlesPane: some View {
        let rows = audioSubtitleRows
        if rows.isEmpty {
            emptyRow("No alternate tracks")
        } else {
            ForEach(rows) { row in
                if let header = row.header {
                    sectionHeader(header)
                }
                if row.isToggle {
                    toggleRow(
                        title: row.title,
                        subtitle: row.subtitle,
                        isOn: row.isSelected,
                        index: row.id,
                        action: row.action
                    )
                } else {
                    selectableRow(
                        title: row.title,
                        isSelected: row.isSelected,
                        index: row.id,
                        action: row.action
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var speedPane: some View {
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
            HStack {
                Text(title).font(.title3)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.headline)
                        .foregroundStyle(palette.accent)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                        Text(subtitle).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isOn ? palette.accent : .secondary)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

    private var availableCategories: [Category] {
        var result: [Category] = []
        if model.hasSelectableAudio
            || model.hasSelectableSubtitles
            || model.engineCapabilities.contains(.dialogEnhance) {
            result.append(.audioSubtitles)
        }
        if model.engineCapabilities.contains(.playbackSpeed) {
            result.append(.speed)
        }
        if model.engineCapabilities.contains(.audioDelay)
            || model.engineCapabilities.contains(.subtitleDelay) {
            result.append(.sync)
        }
        return result
    }

    /// Focus target when the bar first takes focus: the first category, or the
    /// always-present Diagnostics button when no categories apply.
    private var initialFocus: FocusSlot {
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

    private var audioSubtitleRows: [TrackRow] {
        var rows: [TrackRow] = []
        var index = 0
        if model.hasSelectableAudio {
            for (offset, option) in model.audioOptions.enumerated() {
                rows.append(TrackRow(
                    id: index,
                    header: offset == 0 ? "Audio" : nil,
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
                header: model.hasSelectableAudio ? nil : "Audio",
                title: "Dialog Enhance",
                subtitle: "Boost speech clarity in loud mixes",
                isSelected: model.dialogEnhanceEnabled,
                isToggle: true,
                action: { actions.setDialogEnhance(!model.dialogEnhanceEnabled) }
            ))
            index += 1
        }
        if model.hasSelectableSubtitles {
            for (offset, option) in model.subtitleOptions.enumerated() {
                rows.append(TrackRow(
                    id: index,
                    header: offset == 0 ? "Subtitles" : nil,
                    title: option.title,
                    subtitle: "",
                    isSelected: option.isSelected,
                    isToggle: false,
                    action: { actions.selectSubtitle(option.id) }
                ))
                index += 1
            }
        }
        return rows
    }

    private func selectedRowIndex(for category: Category) -> Int {
        switch category {
        case .audioSubtitles:
            return audioSubtitleRows.first(where: { $0.isSelected })?.id
                ?? audioSubtitleRows.first?.id ?? 0
        case .speed:
            return Self.speedPresets.firstIndex(where: { abs(model.playbackSpeed - $0) < 0.001 }) ?? 0
        case .sync:
            return 0
        }
    }

    private func handleExit() {
        if let category = openPanel {
            openPanel = nil
            focus = .button(category)
        } else {
            onExitToSurface()
        }
    }

    // MARK: Formatting

    static let speedPresets: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

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
    /// Whether to float the current-time bubble above the scrub head. Suppressed
    /// while a category panel is open so it can't collide with the panel.
    var showTimeBubble: Bool = true

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let knobX = width * CGFloat(model.progressFraction)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.22))
                    .frame(height: 6)
                Capsule()
                    .fill(.white.opacity(0.35))
                    .frame(width: width * CGFloat(model.bufferedFraction), height: 6)
                Capsule()
                    .fill(palette.accent)
                    .frame(width: knobX, height: 6)
                Circle()
                    .fill(.white)
                    .frame(width: model.isScrubbing ? 22 : 16, height: model.isScrubbing ? 22 : 16)
                    .offset(x: knobX - (model.isScrubbing ? 11 : 8))
                    .shadow(radius: 4)

                if model.isScrubbing {
                    thumbnailPreview(width: width, knobX: knobX)
                } else if showTimeBubble {
                    timeBubble(width: width, knobX: knobX)
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .animation(.easeOut(duration: 0.12), value: model.isScrubbing)
        }
    }

    /// The current playback time, floated just above the scrub head (the focus
    /// indicator), tracking its position. Mirrors the Apple TV transport, where
    /// the playhead carries the time you're currently at.
    @ViewBuilder
    private func timeBubble(width: CGFloat, knobX: CGFloat) -> some View {
        let bubbleWidth: CGFloat = 120
        let clampedX = min(max(bubbleWidth / 2, knobX), width - bubbleWidth / 2)
        Text(PlayerControls.timeLabel(model.displaySeconds))
            .monospacedDigit()
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .shadow(radius: 3)
            .frame(width: bubbleWidth)
            .position(x: clampedX, y: -22)
    }

    @ViewBuilder
    private func thumbnailPreview(width: CGFloat, knobX: CGFloat) -> some View {
        let thumbWidth: CGFloat = 240
        let aspect = previewAspect
        let thumbHeight = thumbWidth / aspect
        let clampedX = min(max(thumbWidth / 2, knobX), width - thumbWidth / 2)

        VStack(spacing: 8) {
            Group {
                if let image = model.previewImage {
                    Image(decorative: image, scale: 1, orientation: .up)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(.black.opacity(0.6))
                }
            }
            .frame(width: thumbWidth, height: thumbHeight)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(.white.opacity(0.85), lineWidth: 2)
            )

            Text(PlayerControls.timeLabel(model.scrubSeconds))
                .monospacedDigit()
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .shadow(radius: 3)
        }
        .frame(width: thumbWidth)
        .position(x: clampedX, y: -thumbHeight / 2 - 30)
    }

    private var previewAspect: CGFloat {
        guard let image = model.previewImage, image.height > 0 else { return 16.0 / 9.0 }
        return CGFloat(image.width) / CGFloat(image.height)
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
#endif
