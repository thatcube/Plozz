#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// A compact, **non-interactive** heads-up panel that overlays the player with
/// live stream diagnostics.
///
/// Tuned for the living room: monospaced digits for stable columns, a
/// semi-opaque dark background for legibility over any frame, and large enough
/// type to read from ~10 feet. `allowsHitTesting(false)` is applied by the host
/// (`PlayerView`) so it never steals focus from the transport controls.
struct PlaybackDiagnosticsOverlay: View {
    let diagnostics: PlaybackDiagnostics?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Playback Diagnostics")
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.bottom, 2)

            if let diagnostics {
                grid(for: diagnostics)
            } else {
                Text("Gathering metrics…")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(24)
        .frame(maxWidth: 680, alignment: .leading)
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        .padding(48)
    }

    @ViewBuilder
    private func grid(for d: PlaybackDiagnostics) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 24, verticalSpacing: 6) {
            optionalRow("Container", d.containerText)
            optionalRow("Video", d.videoLineText)
            optionalRow("Audio", d.audioLineText)
            optionalRow("Subtitles", d.subtitleText)
            row("Source", sourceText(d))
            row("Buffer", d.bufferStatusText)
            row("Network", d.observedBitrateText)
            row("Dropped", "\(d.droppedFramesText) frames")
            optionalRow("Device", d.deviceText)
            optionalRow("Disk", d.diskText)
        }
    }

    private func sourceText(_ d: PlaybackDiagnostics) -> String {
        guard let container = d.container, !container.isEmpty else { return d.mode.displayName }
        return "\(d.mode.displayName) · \(PlaybackDiagnostics.friendlyContainerName(container) ?? container)"
    }

    /// A row that's hidden entirely when its value is the placeholder, so static
    /// facts the provider didn't report don't clutter the panel.
    @ViewBuilder
    private func optionalRow(_ label: String, _ value: String) -> some View {
        if value != PlaybackDiagnostics.placeholder {
            row(label, value)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))
                .gridColumnAlignment(.leading)
            Text(value)
                .font(.system(.callout, design: .monospaced).weight(.semibold))
                .foregroundStyle(.white)
                .gridColumnAlignment(.leading)
        }
    }
}
#endif
