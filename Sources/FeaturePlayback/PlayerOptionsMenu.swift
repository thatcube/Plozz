#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit
import CoreUI

/// The in-player options menu. A focusable SwiftUI surface presented over the
/// playing video by `PlayerInputViewController` when the viewer swipes down,
/// modelled on the best TV media players (Infuse, Jellyfin Swift, Plex, Apple
/// TV app, Kodi):
///
///  * **Top-level rows are flat** — Audio, Subtitles, Speed, Sync — so the two
///    or three controls a viewer reaches for during a session are one tap away
///    rather than buried in a tree (Kodi's biggest UX mistake on tvOS).
///  * **Playback keeps going** while the menu is open (Infuse's pattern), so
///    delay tweaks have *instant audible/visible feedback* and you never lose
///    the dialogue you opened the menu to fix.
///  * **Capability-driven**: rows the active engine can't honour are hidden,
///    not faked. AVPlayer can't shift audio/sub delay, so the Sync row simply
///    isn't there on the native engine — better than a non-functional slider.
///  * Compact, dark, translucent so the picture stays the dominant element.
struct PlayerOptionsMenu: View {
    let model: PlayerControlsModel
    let palette: ThemePalette
    let actions: PlayerOptionsActions
    let onDismiss: () -> Void

    @State private var pane: Pane = .root

    private enum Pane: Hashable {
        case root, audio, subtitles, speed, sync
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            // Translucent backdrop — dim, not opaque. The viewer should still
            // see the change they're making (a subtitle line shifting in sync).
            Color.black.opacity(0.35).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                header
                Divider().background(.white.opacity(0.15))
                content
            }
            .frame(width: 720)
            .padding(.vertical, 30)
            .background(.ultraThinMaterial)
            .colorScheme(.dark)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .padding(.trailing, 60)
            .padding(.vertical, 60)
            .shadow(radius: 30)
        }
        .animation(.easeInOut(duration: 0.18), value: pane)
    }

    @ViewBuilder private var header: some View {
        HStack {
            if pane != .root {
                Button(action: { pane = .root }) {
                    Label("Back", systemImage: "chevron.left")
                        .font(.headline)
                }
                .buttonStyle(.plain)
            }
            Text(titleForPane)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
            Spacer()
        }
        .padding(.horizontal, 30)
        .padding(.bottom, 18)
    }

    private var titleForPane: String {
        switch pane {
        case .root: return "Options"
        case .audio: return "Audio"
        case .subtitles: return "Subtitles"
        case .speed: return "Playback Speed"
        case .sync: return "A/V Sync"
        }
    }

    @ViewBuilder private var content: some View {
        ScrollView {
            VStack(spacing: 0) {
                switch pane {
                case .root: rootPane
                case .audio: audioPane
                case .subtitles: subtitlesPane
                case .speed: speedPane
                case .sync: syncPane
                }
            }
            .padding(.vertical, 12)
        }
    }

    // MARK: Root

    @ViewBuilder private var rootPane: some View {
        if model.hasSelectableAudio || model.engineCapabilities.contains(.dialogEnhance) {
            rootRow(
                title: "Audio",
                value: currentAudioTitle,
                systemImage: "speaker.wave.2.fill"
            ) { pane = .audio }
        }
        if model.hasSelectableSubtitles {
            rootRow(
                title: "Subtitles",
                value: currentSubtitleTitle,
                systemImage: "captions.bubble"
            ) { pane = .subtitles }
        }
        if model.engineCapabilities.contains(.playbackSpeed) {
            rootRow(
                title: "Speed",
                value: PlayerOptionsMenu.speedLabel(model.playbackSpeed),
                systemImage: "speedometer"
            ) { pane = .speed }
        }
        let canSync = model.engineCapabilities.contains(.audioDelay)
            || model.engineCapabilities.contains(.subtitleDelay)
        if canSync {
            rootRow(
                title: "A/V Sync",
                value: syncSummary,
                systemImage: "slider.horizontal.below.square.and.square.filled"
            ) { pane = .sync }
        }
    }

    private func rootRow(
        title: String,
        value: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 18) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .frame(width: 36)
                Text(title).font(.title3.weight(.medium))
                Spacer()
                Text(value)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Audio

    @ViewBuilder private var audioPane: some View {
        if model.hasSelectableAudio {
            VStack(spacing: 0) {
                ForEach(model.audioOptions) { option in
                    selectableRow(title: option.title, isSelected: option.isSelected) {
                        actions.selectAudio(option.id)
                    }
                }
            }
        }
        if model.engineCapabilities.contains(.dialogEnhance) {
            Divider().background(.white.opacity(0.1)).padding(.horizontal, 24).padding(.vertical, 8)
            Toggle(isOn: Binding(
                get: { model.dialogEnhanceEnabled },
                set: { actions.setDialogEnhance($0) }
            )) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Dialog Enhance").font(.title3.weight(.medium))
                    Text("Boost speech clarity in loud mixes")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 14)
        }
    }

    // MARK: Subtitles

    @ViewBuilder private var subtitlesPane: some View {
        VStack(spacing: 0) {
            ForEach(model.subtitleOptions) { option in
                selectableRow(title: option.title, isSelected: option.isSelected) {
                    actions.selectSubtitle(option.id)
                }
            }
        }
    }

    // MARK: Speed

    private static let speedPresets: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    @ViewBuilder private var speedPane: some View {
        VStack(spacing: 0) {
            ForEach(PlayerOptionsMenu.speedPresets, id: \.self) { speed in
                selectableRow(
                    title: PlayerOptionsMenu.speedLabel(speed),
                    isSelected: abs(model.playbackSpeed - speed) < 0.001
                ) {
                    actions.setPlaybackSpeed(speed)
                }
            }
        }
    }

    static func speedLabel(_ speed: Double) -> String {
        if abs(speed - speed.rounded()) < 0.001 {
            return String(format: "%.0f×", speed)
        }
        return String(format: "%.2f×", speed).replacingOccurrences(of: "0×", with: "×")
    }

    // MARK: Sync

    @ViewBuilder private var syncPane: some View {
        if model.engineCapabilities.contains(.audioDelay) {
            delayRow(
                title: "Audio Delay",
                value: model.audioDelaySeconds,
                onAdjust: { delta in
                    actions.setAudioDelay(model.audioDelaySeconds + delta)
                },
                onReset: { actions.setAudioDelay(0) }
            )
        }
        if model.engineCapabilities.contains(.subtitleDelay) {
            delayRow(
                title: "Subtitle Delay",
                value: model.subtitleDelaySeconds,
                onAdjust: { delta in
                    actions.setSubtitleDelay(model.subtitleDelaySeconds + delta)
                },
                onReset: { actions.setSubtitleDelay(0) }
            )
        }
    }

    private func delayRow(
        title: String,
        value: TimeInterval,
        onAdjust: @escaping (TimeInterval) -> Void,
        onReset: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.title3.weight(.medium))
                Spacer()
                Text(PlayerOptionsMenu.delayLabel(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button(action: { onAdjust(-0.05) }) { stepLabel("−50 ms") }
                    .buttonStyle(.bordered)
                Button(action: { onAdjust(-0.5) }) { stepLabel("−500 ms") }
                    .buttonStyle(.bordered)
                Button(action: onReset) { stepLabel("Reset") }
                    .buttonStyle(.bordered)
                Button(action: { onAdjust(0.5) }) { stepLabel("+500 ms") }
                    .buttonStyle(.bordered)
                Button(action: { onAdjust(0.05) }) { stepLabel("+50 ms") }
                    .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 16)
    }

    private func stepLabel(_ text: String) -> some View {
        Text(text).font(.callout.weight(.medium)).padding(.horizontal, 4)
    }

    static func delayLabel(_ seconds: TimeInterval) -> String {
        let ms = Int((seconds * 1000).rounded())
        if ms == 0 { return "0 ms" }
        return (ms > 0 ? "+\(ms) ms" : "\(ms) ms")
    }

    // MARK: Shared

    private func selectableRow(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
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
            .padding(.horizontal, 30)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var currentAudioTitle: String {
        model.audioOptions.first(where: { $0.isSelected })?.title ?? "—"
    }

    private var currentSubtitleTitle: String {
        model.subtitleOptions.first(where: { $0.isSelected })?.title ?? "Off"
    }

    private var syncSummary: String {
        let a = model.audioDelaySeconds
        let s = model.subtitleDelaySeconds
        if a == 0 && s == 0 { return "Auto" }
        var parts: [String] = []
        if a != 0 { parts.append("A " + PlayerOptionsMenu.delayLabel(a)) }
        if s != 0 { parts.append("S " + PlayerOptionsMenu.delayLabel(s)) }
        return parts.joined(separator: " · ")
    }
}

/// Lightweight value-type bag of options-menu callbacks. Mirrors `PlayerActions`
/// but only the tunable subset so the menu stays presentation-only.
@MainActor
struct PlayerOptionsActions {
    var selectAudio: (Int) -> Void = { _ in }
    var selectSubtitle: (Int) -> Void = { _ in }
    var setPlaybackSpeed: (Double) -> Void = { _ in }
    var setAudioDelay: (TimeInterval) -> Void = { _ in }
    var setSubtitleDelay: (TimeInterval) -> Void = { _ in }
    var setDialogEnhance: (Bool) -> Void = { _ in }
}
#endif
