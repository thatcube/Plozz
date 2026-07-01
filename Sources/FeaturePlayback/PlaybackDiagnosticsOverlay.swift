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
        .padding(40)
        .frame(maxWidth: 740, alignment: .leading)
        .plozzGlassPanel(cornerRadius: 64, scrimOpacity: 0.45, refractEdgesOnly: true)
        // Pinned to the player's top-left. Equal top/left margin (the overlay host
        // ignores the safe area) so it hugs the corner rather than the tvOS
        // overscan inset, which is wider on the sides than the top.
        .padding(48)
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
                if let provider = diagnostics?.sourceProvider {
                    HStack(spacing: 6) {
                        Image(provider == .plex ? "PlexLogo" : "JellyfinLogo")
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 16, height: 16)
                            .foregroundStyle(providerTint(provider))
                            .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
                        Text("Playing from \(diagnostics?.serverName ?? provider.displayName)")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(palette.primaryText)
                            .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
                    }
                }
                if let engine = diagnostics?.engineName {
                    Text(engine)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(palette.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(palette.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
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
            optionalRow("Codec", d.videoCodecText)
            optionalRow("Resolution", d.resolutionWithQualityText)
            optionalRow("Frame Rate", d.frameRateText)
            optionalRow("Bitrate", d.indicatedBitrateText)
            optionalRow("HDR", d.hdrText)
            optionalRow("Dolby Vision", d.dolbyVisionText)
            optionalRow("Color", d.colorText)
            optionalRow("Codec Tag", d.videoCodecTagText)
        }
    }

    @ViewBuilder
    private func audioSection(_ d: PlaybackDiagnostics) -> some View {
        section("AUDIO") {
            optionalRow("Codec", d.audioCodecText)
            optionalRow("Channels", d.audioChannelsText)
            optionalRow("Sample Rate", d.audioSampleRateText)
            optionalRow("Bitrate", d.audioBitrateText)
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
            optionalRow("Live FPS", d.observedFpsText)
            optionalRow("Network", d.observedBitrateText)
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
        return d.mode.displayName
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
        case .plex: return Color(red: 0xF5 / 255, green: 0xC5 / 255, blue: 0x18 / 255)
        }
    }
}

#Preview("Diagnostics HUD") {
    var d = PlaybackDiagnostics(
        videoCodec: "HEVC", audioCodec: "EAC3", audioChannels: 6, container: "mkv",
        mode: .directPlay, engineName: "Plozzigen",
        droppedVideoFrames: 0, frameRate: 23.976, observedFps: 23.9
    )
    d.serverName = "Brandoland"
    d.sourceProvider = .plex
    d.observedBitrate = 11_900_000
    return ZStack {
        LinearGradient(colors: [.cyan, .white, .orange], startPoint: .topLeading, endPoint: .bottomTrailing)
        PlaybackDiagnosticsOverlay(diagnostics: d)
    }
    .ignoresSafeArea()
}
#endif
