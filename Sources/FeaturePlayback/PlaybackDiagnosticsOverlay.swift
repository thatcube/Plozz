#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// A compact, **non-interactive** heads-up panel that overlays the player with
/// live stream diagnostics.
///
/// Tuned for the living room: monospaced digits for stable columns, a Liquid
/// Glass surface (with a faint theme-aware scrim) for legibility over any frame,
/// and type sized to read from the couch. `allowsHitTesting(false)` is applied
/// by the host (`PlayerView`) so it never steals focus from the transport
/// controls.
struct PlaybackDiagnosticsOverlay: View {
    let diagnostics: PlaybackDiagnostics?

    @Environment(\.themePalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Playback Diagnostics")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(palette.primaryText)
                .padding(.bottom, 1)

            if let diagnostics {
                grid(for: diagnostics)
            } else {
                Text("Gathering metrics…")
                    .font(.system(size: 15, design: .monospaced))
                    .foregroundStyle(palette.secondaryText)
            }
        }
        .padding(16)
        .frame(maxWidth: 720, alignment: .leading)
        .plozzGlassPanel(cornerRadius: 14)
        .padding(36)
    }

    @ViewBuilder
    private func grid(for d: PlaybackDiagnostics) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 18, verticalSpacing: 4) {
            optionalRow("Engine", d.engineName ?? PlaybackDiagnostics.placeholder)
            optionalRow("Container", d.containerText)
            optionalRow("Video", d.videoLineText)
            optionalRow("Audio", d.audioLineText)
            optionalRow("Subtitles", d.subtitleText)
            row("Source", sourceText(d))
            // Runtime health — the "is the device keeping up?" rows. Hidden when
            // the active engine can't report them (e.g. AVPlayer shows the access
            // log's "Dropped" row below instead). Software decode and main-thread
            // hitches are flagged so the cause of stutter is obvious.
            optionalRow("Decode", d.decodeText, warn: d.isSoftwareDecoding)
            optionalRow("Render", d.renderRateText)
            optionalRow("Frame drops", d.engineDropsText)
            optionalRow("Late rate", d.lateFrameRateText)
            row("Buffer", d.bufferStatusText)
            row("Network", d.observedBitrateText)
            row("Dropped", "\(d.droppedFramesText) frames")
            optionalRow("Main thread", d.mainThreadText, warn: d.hasMainThreadHitch)
            optionalRow("Device", d.deviceText)
            optionalRow("Disk", d.diskText)
        }
    }

    private func sourceText(_ d: PlaybackDiagnostics) -> String {
        guard let label = PlaybackDiagnostics.containerLabel(d.container) else { return d.mode.displayName }
        return "\(d.mode.displayName) · \(label)"
    }

    /// A row that's hidden entirely when its value is the placeholder, so static
    /// facts the provider didn't report don't clutter the panel.
    @ViewBuilder
    private func optionalRow(_ label: String, _ value: String, warn: Bool = false) -> some View {
        if value != PlaybackDiagnostics.placeholder {
            row(label, value, warn: warn)
        }
    }

    /// A row hidden entirely when its value is `nil` — for the engine-health rows
    /// that only some engines report.
    @ViewBuilder
    private func optionalRow(_ label: String, _ value: String?, warn: Bool = false) -> some View {
        if let value {
            row(label, value, warn: warn)
        }
    }

    private func row(_ label: String, _ value: String, warn: Bool = false) -> some View {
        GridRow {
            Text(label)
                .font(.system(size: 15, design: .monospaced))
                .foregroundStyle(palette.secondaryText)
                .gridColumnAlignment(.leading)
            Text(value)
                .font(.system(size: 15, design: .monospaced).weight(.semibold))
                .foregroundStyle(warn ? Color.orange : palette.primaryText)
                .gridColumnAlignment(.leading)
        }
    }
}
#endif
