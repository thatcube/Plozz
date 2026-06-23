#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit
import CoreUI

/// Lightweight value-type bag of options callbacks. Mirrors the tunable subset
/// of `PlayerActions` so the control bar stays presentation-only.
@MainActor
struct PlayerOptionsActions {
    var selectAudio: (Int) -> Void = { _ in }
    var selectSubtitle: (Int) -> Void = { _ in }
    var setPlaybackSpeed: (Double) -> Void = { _ in }
    var setAudioDelay: (TimeInterval) -> Void = { _ in }
    var setSubtitleDelay: (TimeInterval) -> Void = { _ in }
    var setDialogEnhance: (Bool) -> Void = { _ in }
}

/// Netflix-style bottom control bar for the custom player: a **focusable row of
/// native tvOS buttons** (Audio & Subtitles · Speed · A/V Sync) with category
/// panels that open *above* the row. Modelled on the best TV players:
///
///  * **Everything lives at the bottom** (Netflix / YouTube / Disney+) — the row
///    a viewer reaches for during a session is one focus-move down from the
///    scrubber, never buried in a tree.
///  * **Native focus throughout** — standard tvOS Buttons, so the parallax
///    highlight, focus navigation, and Select activation are the system's, not a
///    hand-rolled imitation.
///  * **Playback keeps going** while the bar is open (Infuse) so delay/track
///    tweaks have instant feedback.
///  * **Capability-driven** — rows the active engine can't honour are hidden,
///    not faked (AVPlayer has no A/V-sync row).
///
/// Focus enters this surface from the UIKit scrub layer on swipe-down/down and
/// returns to it on up / Menu via `onExitToSurface`.
struct PlayerControlBar: View {
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
        case row(Int)
    }

    @State private var openPanel: Category?
    @FocusState private var focus: FocusSlot?

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear
            if model.controlBarVisible {
                VStack(alignment: .leading, spacing: 22) {
                    if let openPanel {
                        panelContainer(for: openPanel)
                    }
                    buttonRow
                }
                .padding(.horizontal, 60)
                .padding(.bottom, 48)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.2), value: model.controlBarVisible)
        .animation(.easeInOut(duration: 0.2), value: openPanel)
        .onChange(of: model.controlBarVisible) { _, visible in
            openPanel = nil
            focus = visible ? .button(firstCategory ?? .audioSubtitles) : nil
        }
        .onChange(of: openPanel) { _, panel in
            if let panel { focus = .row(selectedRowIndex(for: panel)) }
        }
        .onExitCommand { handleExit() }
        .onMoveCommand { direction in
            if direction == .up && openPanel == nil { onExitToSurface() }
        }
    }

    // MARK: Button row

    private var buttonRow: some View {
        HStack(spacing: 24) {
            ForEach(availableCategories, id: \.self) { category in
                Button {
                    toggle(category)
                } label: {
                    Label(category.title, systemImage: category.icon)
                        .font(.headline)
                        .padding(.horizontal, 6)
                }
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
            .frame(maxHeight: 520)
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

    private var firstCategory: Category? { availableCategories.first }

    /// Flat, indexed rows for the combined Audio & Subtitles pane. The `id` is the
    /// focus-slot index so we can land initial focus on the active selection.
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
}
#endif
