#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// A compact, **non-interactive** heads-up panel that overlays the player with
/// live stream diagnostics, organized into logical sections.
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
        VStack(alignment: .leading, spacing: 0) {
            // Header with provider logo
            header

            if let diagnostics {
                sectionsGrid(for: diagnostics)
            } else {
                Text("Gathering metrics…")
                    .font(.system(size: 15, design: .monospaced))
                    .foregroundStyle(palette.secondaryText)
                    .padding(.top, 8)
            }
        }
        .padding(16)
        .frame(maxWidth: 740, alignment: .leading)
        .plozzGlassPanel(cornerRadius: 14)
        .padding(36)
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Playback Diagnostics")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(palette.primaryText)
                Spacer()
                if let engine = diagnostics?.engineName {
                    Text(engine)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(palette.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(palette.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                }
            }
            if let provider = diagnostics?.sourceProvider {
                HStack(spacing: 6) {
                    Image(provider == .plex ? "PlexLogo" : "JellyfinLogo")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 14, height: 14)
                        .foregroundStyle(providerTint(provider))
                    Text("Playing from \(diagnostics?.serverName ?? provider.displayName)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(palette.secondaryText)
                }
            }
        }
        .padding(.bottom, 10)
    }

    // MARK: - Sections

    @ViewBuilder
    private func sectionsGrid(for d: PlaybackDiagnostics) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sourceSection(d)
            videoSection(d)
            audioSection(d)
            subtitleSection(d)
            playbackSection(d)
            if d.mode == .localRemux {
                remuxSection(d)
            }
            systemSection(d)
        }
    }

    @ViewBuilder
    private func sourceSection(_ d: PlaybackDiagnostics) -> some View {
        section("SOURCE") {
            row("Delivery", sourceText(d))
            optionalRow("Stream", d.streamTransportText)
            optionalRow("Container", d.containerText)
        }
    }

    @ViewBuilder
    private func videoSection(_ d: PlaybackDiagnostics) -> some View {
        section("VIDEO") {
            optionalRow("Codec", d.videoLineText)
            optionalRow("Color", d.colorText)
            optionalRow("Dolby Vision", d.dolbyVisionText)
            optionalRow("Codec Tag", d.videoCodecTagText)
        }
    }

    @ViewBuilder
    private func audioSection(_ d: PlaybackDiagnostics) -> some View {
        section("AUDIO") {
            optionalRow("Codec", d.audioLineText)
            optionalRow("Output", d.audioOutputText)
        }
    }

    @ViewBuilder
    private func subtitleSection(_ d: PlaybackDiagnostics) -> some View {
        if d.subtitleText != PlaybackDiagnostics.placeholder {
            section("SUBTITLES") {
                row("Track", d.subtitleText)
            }
        }
    }

    @ViewBuilder
    private func playbackSection(_ d: PlaybackDiagnostics) -> some View {
        section("PLAYBACK") {
            optionalRow("Position", d.positionText)
            optionalRow("Seekable", d.seekWindowText)
            optionalRow("State", d.playbackStateText)
            row("Buffer", d.bufferStatusText)
            row("Dropped", "\(d.droppedFramesText) frames")
            optionalRow("Network", d.observedBitrateText)
        }
    }

    @ViewBuilder
    private func remuxSection(_ d: PlaybackDiagnostics) -> some View {
        section("LOCAL REMUX") {
            optionalRow("Strategy", d.remuxStrategyText)
            optionalRow("Transport", d.remuxTransportText)
            optionalRow("TTFF", d.remuxTimeToFirstFrameText)
            optionalRow("Seek", d.remuxSeekLatencyText)
            optionalRow("Stalls", d.remuxStallsText)
            optionalRow("Segments", d.remuxSegmentsText)
            optionalRow("Bytes", d.remuxBytesText)
            optionalRow("Cache", d.remuxUsageText)
            optionalRow("Harness", d.remuxHarnessText)
        }
    }

    @ViewBuilder
    private func systemSection(_ d: PlaybackDiagnostics) -> some View {
        section("SYSTEM") {
            optionalRow("Device", d.deviceText)
            optionalRow("Disk", d.diskText)
            optionalRow("Memory", d.memoryText)
            optionalRow("Thermal", d.thermalText)
            optionalRow("Instances", d.liveInstancesText)
        }
    }

    // MARK: - Section builder

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(palette.secondaryText.opacity(0.6))
                .padding(.bottom, 1)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 3) {
                rows()
            }
        }
    }

    // MARK: - Rows

    private func sourceText(_ d: PlaybackDiagnostics) -> String {
        let mode: String
        if d.mode == .localRemux, d.remux?.strategyID == LocalRemuxStrategyChoice.referenceServerRemuxID {
            mode = "Server HLS baseline"
        } else {
            mode = d.mode.displayName
        }
        guard let label = PlaybackDiagnostics.containerLabel(d.container) else { return mode }
        return "\(mode) · \(label)"
    }

    @ViewBuilder
    private func optionalRow(_ label: String, _ value: String) -> some View {
        if value != PlaybackDiagnostics.placeholder {
            row(label, value)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(palette.secondaryText)
                .frame(width: 110, alignment: .leading)
                .gridColumnAlignment(.leading)
            Text(value)
                .font(.system(size: 14, design: .monospaced).weight(.semibold))
                .foregroundStyle(palette.primaryText)
                .gridColumnAlignment(.leading)
        }
    }

    // MARK: - Helpers

    private func providerTint(_ provider: ProviderKind) -> Color {
        switch provider {
        case .jellyfin: return Color(red: 0.53, green: 0.38, blue: 0.95)
        case .plex: return Color(red: 0xE5 / 255, green: 0xA0 / 255, blue: 0x0D / 255)
        }
    }
}
#endif
