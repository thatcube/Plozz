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
        HStack(spacing: 12) {
            ScrubBar(
                model: model,
                palette: palette,
                showThumbOverlay: openPanel == nil,
                leadingInset: 60,
                trailingInset: 60 + 12 + 120
            )
                .frame(height: 44)
                .frame(maxWidth: .infinity)
            // Remaining time pinned to the end of the bar. Fixed width so the
            // track never resizes as the digits change.
            Text("-" + Self.timeLabel(max(0, model.duration - model.displaySeconds)))
                .monospacedDigit()
                .font(.callout)
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 120, alignment: .trailing)
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

                if model.isScrubbing {
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
    /// so they can't shift it. A backward skip's −10 (and, if the seek is still
    /// resolving, the loading spinner) sits to the left; a forward skip's +10, the
    /// spinner for a forward seek / plain scrub, and the circular pause glyph sit
    /// to the right. Clamped so the time never runs off either edge.
    @ViewBuilder
    private func thumbOverlay(width: CGFloat, knobX: CGFloat) -> some View {
        let margin: CGFloat = 120
        let cx = min(max(margin, knobX), max(margin, width - margin))
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

    /// Left of the current time: the −10 glyph after a backward skip, replaced by
    /// the loading spinner if a backward seek is still resolving.
    @ViewBuilder private var leftSlot: some View {
        if model.skipHintVisible && !model.skipHintForward {
            skipGlyph(forward: false)
        } else if model.isSeeking && model.seekIndicatorOnLeft {
            spinner
        }
    }

    /// Right of the current time: the +10 glyph after a forward skip; otherwise
    /// the spinner for a forward seek / plain scrub; otherwise the circular pause
    /// glyph while paused. All share this one slot.
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

    /// Compact ±10s glyph. It persists for the whole skip burst (no per-press
    /// teardown), and a subtle scale dip gives "pressed" feedback on each press.
    private func skipGlyph(forward: Bool) -> some View {
        Image(systemName: forward ? "goforward.10" : "gobackward.10")
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
        let thumbWidth: CGFloat = 420
        let aspect = previewAspect
        let thumbHeight = thumbWidth / aspect
        let edgeMargin: CGFloat = 16
        let minX = -leadingInset + thumbWidth / 2 + edgeMargin
        let maxX = width + trailingInset - thumbWidth / 2 - edgeMargin
        let clampedX = min(max(minX, knobX), max(minX, maxX))
        let corner: CGFloat = 18
        let border: CGFloat = 12

        let content = Group {
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
#endif
