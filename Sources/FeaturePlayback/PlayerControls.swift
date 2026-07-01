#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit
import CoreUI

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
        .onPlayPauseCommand { actions.togglePlayPause() }
        .onMoveCommand { direction in
            if direction == .up && openPanel == nil { onExitToSurface() }
        }
    }

    // MARK: Bottom cluster (title + scrubber + buttons)

    private var bottomCluster: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let openPanel {
                panelContainer(for: openPanel)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            titleBlock
            scrubberRow
            buttonRow
        }
        .animation(.easeInOut(duration: 0.2), value: openPanel)
        .animation(Self.transportFadeAnimation(scrubbing: model.isScrubbing), value: model.isScrubbing)
        .padding(.horizontal, 60)
        .padding(.top, 90)
        .padding(.bottom, 48)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
        )
    }

    // MARK: Title (episode line above the series title, bottom-left)

    /// The episode line ("S1, E2 • Episode Title") sits *above* the prominent
    /// series/movie title, Apple-TV style. The whole block lives at the bottom
    /// just above the scrub bar and fades out fast while scrubbing so the scrub
    /// surface stays uncluttered (the times stay).
    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !model.subtitle.isEmpty {
                Text(model.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }
            Text(model.title)
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .shadow(color: .black.opacity(0.4), radius: 4, y: 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(model.isScrubbing ? 0 : 1)
        .offset(y: model.isScrubbing ? 8 : 0)
        .allowsHitTesting(!model.isScrubbing)
    }

    private var scrubberRow: some View {
        VStack(spacing: 8) {
            ScrubBar(
                model: model,
                palette: palette,
                leadingInset: 60,
                trailingInset: 60
            )
                .frame(height: 44)
                .frame(maxWidth: .infinity)
            underBarTimes
                .frame(height: 30)
                .frame(maxWidth: .infinity)
        }
    }

    /// The time row *under* the bar. The current-position label tracks the scrub
    /// head horizontally — all the way to the very end — with the status glyph
    /// hanging off its right edge (free to slide into the trailing padding). The
    /// remaining time stays pinned at the right but fades out + away once the
    /// moving current time closes within ~16px of it, so the current time is never
    /// blocked. Everything is absolutely positioned inside a fixed-height zone so
    /// the bar never shifts when the glyph appears/clears.
    private var underBarTimes: some View {
        let fadeGap: CGFloat = 16
        let curLabel = Self.timeLabel(model.displaySeconds)
        let remLabel = "-" + Self.timeLabel(max(0, model.duration - model.displaySeconds))
        // Deterministic, synchronous text widths. The SwiftUI `.background`/
        // `PreferenceKey` measuring trick does NOT propagate through `.hidden()`
        // here (verified on-device: the preference never fired, so the widths
        // stayed 0 → no right-edge clamp and no fade). Measuring with UIKit using
        // the matching monospaced-digit font is exact and needs no layout pass.
        let curW = Self.measuredTimeWidth(curLabel)
        let remW = Self.measuredTimeWidth(remLabel)
        return GeometryReader { geo in
            let width = geo.size.width
            let midY = geo.size.height / 2
            let knobX = width * CGFloat(model.progressFraction)
            let halfCur = curW / 2
            // The scrub track spans the full zone width [0, width] (the ScrubBar's
            // insets only let the thumbnail overhang — the track itself is full
            // width), so the head maps straight to knobX. Centre the label on the
            // head, but clamp so its RIGHT edge stops exactly at the bar's right
            // edge (x = width) and its LEFT edge never crosses the bar's left edge.
            let centerX = min(max(knobX, halfCur), max(halfCur, width - halfCur))
            let currentRightEdge = centerX + halfCur
            // The remaining time is pinned to the bar's right edge; its left edge
            // sits at width - remW.
            let remainingLeftEdge = width - remW
            // When the status glyph (pause/seek/skip) is showing it hangs ~40px
            // past the current-time text's right edge, so NEAR THE VERY END it can
            // land on top of the remaining time even though the time text hasn't
            // reached it. Treat the glyph's right edge as the collision point
            // whenever it's visible (it's faded out during an active scrub) so the
            // remaining time still does the same fade — just earlier by the glyph's
            // reach. Outside this edge case the glyph isn't near the end, so the
            // time is never hidden early.
            let glyphShown = !model.isScrubbing
                && (model.skipHintVisible || (model.isPaused && model.intendsPause) || model.isSeeking)
            let glyphReach: CGFloat = glyphShown ? 40 : 0
            // Fade the remaining time once the current time's (or glyph's) right
            // edge closes within the gap.
            let remainingHidden = currentRightEdge + glyphReach + fadeGap >= remainingLeftEdge

            // Current position — centred on the (clamped) scrub head, tracking it.
            // The glyph hangs off the right edge as an overlay so it can't shift
            // the time, and fades (no movement) while actively scrubbing, returning
            // when the scrub ends, like the other transport elements.
            Text(curLabel)
                .monospacedDigit()
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .fixedSize()
                .shadow(radius: 3)
                .overlay(alignment: .trailing) {
                    statusGlyph
                        .frame(width: 30, height: 30)
                        .offset(x: 40)
                        .opacity(model.isScrubbing ? 0 : 1)
                        // Fades with the rest of the transport (title + buttons):
                        // vanish instantly when a scrub starts, then fade back in
                        // together with them after a delay once it stops — so rapid
                        // multi-scrubs don't flash anything back between swipes.
                        .animation(
                            Self.transportFadeAnimation(scrubbing: model.isScrubbing),
                            value: model.isScrubbing
                        )
                }
                .position(x: centerX, y: midY)

            // Remaining time, pinned at the bar's right edge — fades out (in
            // place, no drift) when the current time / glyph approaches.
            Text(remLabel)
                .monospacedDigit()
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))
                .fixedSize()
                .shadow(radius: 3)
                .opacity(remainingHidden ? 0 : 1)
                .animation(.easeOut(duration: 0.15), value: remainingHidden)
                .frame(width: width, alignment: .trailing)
                .position(x: width / 2, y: midY)
        }
        // No `.animation(value: isPaused/isSeeking)` here on purpose. The glyph's
        // pause↔spinner swap must be INSTANT: the pause glyph is mounted (hidden)
        // during a scrub, and animating the swap let it play a scale+opacity
        // *removal* transition just as the parent overlay faded back in — you'd see
        // a half-size pause icon try to appear and vanish on a seek-without-
        // pausing. The parent's `isScrubbing` transport fade still handles the
        // overall reveal; the content underneath swaps with no animation of its own.
    }

    /// Status glyph beside the current time under the bar. Priority, highest
    /// first:
    ///  1. a forward/back skip indicator during a skip burst,
    ///  2. the loading spinner while a committed seek is resolving — this wins
    ///     over the pause glyph UNCONDITIONALLY: while anything is loading the
    ///     viewer must see ONLY the spinner, never a pause icon alongside it,
    ///  3. a circular pause glyph while *intentionally* paused (a landed,
    ///     finished-loading pause).
    ///
    /// The pause glyph requires `isPaused` AND `intendsPause` AND `!isScrubbing`.
    /// `intendsPause` filters out the engine's transient post-seek pause (the
    /// viewer never pressed pause). `!isScrubbing` is the decisive one: a scrub
    /// pauses the stream for preview, so `isPaused`/`intendsPause` are BOTH true
    /// mid-scrub — without this gate the pause glyph is the rendered content
    /// during the scrub, and at commit its swap to the spinner gets animated by
    /// the overlay's `isScrubbing` fade, cross-dissolving a half-faded pause icon
    /// into the spinner (the seek-without-pausing flicker). Gating on
    /// `!isScrubbing` keeps the content at none→spinner across the whole
    /// scrub→commit window, so a manual pause is the ONLY thing that ever shows it.
    @ViewBuilder private var statusGlyph: some View {
        if model.skipHintVisible {
            Image(systemName: model.skipHintForward
                ? model.skipForwardInterval.forwardSymbol
                : model.skipBackwardInterval.backwardSymbol)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .transition(.scale(scale: 0.5).combined(with: .opacity))
        } else if model.isSeeking {
            ProgressView()
                .tint(.white)
                .controlSize(.small)
        } else if model.isPaused && model.intendsPause && !model.isScrubbing {
            Image(systemName: "pause.circle.fill")
                .font(.system(size: 24))
                .foregroundStyle(.white)
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
                        .labelStyle(.iconOnly)
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
                .labelStyle(.iconOnly)
            }
            .playerGlassButton(prominent: model.diagnosticsEnabled)
            .focused($focus, equals: .diagnostics)
        }
        .opacity(model.isScrubbing ? 0 : 1)
        .offset(y: model.isScrubbing ? 8 : 0)
        .allowsHitTesting(!model.isScrubbing)
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

    /// Exact rendered width of an under-bar time label, measured synchronously
    /// with UIKit using the matching monospaced-digit font. We measure here (not
    /// via SwiftUI `PreferenceKey`s) because the `.background`/preference trick
    /// does not propagate through `.hidden()` on tvOS — verified on-device, the
    /// preference never fired so the labels never clamped or faded.
    static func measuredTimeWidth(_ string: String) -> CGFloat {
        let pointSize = UIFont.preferredFont(forTextStyle: .callout).pointSize
        let font = UIFont.monospacedDigitSystemFont(ofSize: pointSize, weight: .semibold)
        let bounds = (string as NSString).size(withAttributes: [.font: font])
        return ceil(bounds.width)
    }

    /// Shared asymmetric fade for the transport chrome that hides while scrubbing
    /// (title block, button row, and the under-bar status glyph): it vanishes
    /// instantly when a scrub *starts* (quick ease) but waits before fading back
    /// in once it *stops* (delayed ease), so all those elements return together
    /// and rapid multi-scrubs never flash them back between swipes. Evaluated
    /// against the NEW `isScrubbing` value, so the start→hide and stop→show
    /// transitions each pick the matching curve.
    static func transportFadeAnimation(scrubbing: Bool) -> Animation {
        scrubbing
            ? .easeOut(duration: 0.1)
            : .easeOut(duration: 0.2).delay(0.45)
    }
}

/// The scrub track: buffered + played fill, a knob, and a floating trickplay
/// thumbnail positioned over the scrub head while scrubbing.
private struct ScrubBar: View {
    let model: PlayerControlsModel
    let palette: ThemePalette
    /// Horizontal distance from the scrub track's leading/trailing edge out to the
    /// screen edge, so the trickplay thumbnail can extend past the track (but not
    /// off-screen).
    var leadingInset: CGFloat = 0
    var trailingInset: CGFloat = 0

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
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .animation(.easeOut(duration: 0.12), value: model.isScrubbing)
            .animation(.easeOut(duration: 0.2), value: model.controlBarVisible)
            .animation(.easeOut(duration: 0.2), value: model.controlsVisible)
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

    @ViewBuilder
    private func thumbnailPreview(width: CGFloat, knobX: CGFloat) -> some View {
        if let image = model.previewImage {
            // ~15% larger than the previous 420pt thumbnail.
            let thumbWidth: CGFloat = 483
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

            // Float the trickplay thumbnail above the scrub bar (bar is centred
            // at y=0 in this GeometryReader). `thumbnailLift` is the gap from the
            // bar centre to the *bottom* of the thumbnail — kept tight so the
            // preview hugs the bar.
            let thumbnailLift: CGFloat = 34
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
            .position(x: clampedX, y: -(thumbnailLift + thumbHeight / 2))
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
#endif
