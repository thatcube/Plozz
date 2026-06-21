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
        .frame(maxWidth: 560, alignment: .leading)
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
            row("Resolution", d.resolutionText)
            row("Frame rate", d.frameRateText)
            row("HDR", d.hdr.displayName)
            row("Video", d.videoCodecText)
            row("Audio", d.audioCodecText)
            row("Source", sourceText(d))
            row("Bitrate", "\(d.indicatedBitrateText) ⋅ obs \(d.observedBitrateText)")
            row("Buffer", "\(d.bufferText) ahead")
            row("Dropped", "\(d.droppedFramesText) frames")
        }
    }

    private func sourceText(_ d: PlaybackDiagnostics) -> String {
        guard let container = d.container, !container.isEmpty else { return d.mode.displayName }
        return "\(d.mode.displayName) · \(container)"
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
