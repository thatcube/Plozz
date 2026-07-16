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
        .frame(maxWidth: 820, alignment: .leading)
        .plozzGlassPanel(
            cornerRadius: PlozzTheme.Metrics.playerPanelCornerRadius,
            scrimOpacity: 0.45,
            refractEdgesOnly: true
        )
        // Pinned to the player's top-left corner (the overlay host ignores the
        // safe area so this hugs the corner, not the wider tvOS overscan inset).
        .padding(.leading, 48)
        .padding(.top, 32)
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
                        ProviderBrandMark(provider: provider, size: 16, showsBackground: false)
                            .frame(width: 16, height: 16)
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
        // Two columns so the HUD reads at a glance instead of running nearly the
        // full screen height: content facts on the left (source/video/audio),
        // session + device health on the right (subtitles/playback/system).
        HStack(alignment: .top, spacing: 40) {
            VStack(alignment: .leading, spacing: 12) {
                sourceSection(d)
                videoSection(d)
                audioSection(d)
            }
            VStack(alignment: .leading, spacing: 12) {
                subtitleSection(d)
                playbackSection(d)
                systemSection(d)
            }
        }
    }

    @ViewBuilder
    private func sourceSection(_ d: PlaybackDiagnostics) -> some View {
        section("SOURCE") {
            optionalRow("File", d.sourceFileNameText)
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
            // Nominal frame rate + live observed FPS folded into one row.
            optionalRow("Frame Rate", frameRateCombined(d))
            // Indicated (source) bitrate + live network bitrate folded together.
            optionalRow("Bitrate", videoBitrateCombined(d))
            // HDR format + Dolby Vision profile folded into a single HDR row.
            optionalRow("HDR", hdrCombined(d))
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
        // Live FPS + Network bitrate moved up into the VIDEO rows they mirror, so
        // PLAYBACK is just the session-state facts.
        section("PLAYBACK") {
            optionalRow("Position", d.positionText)
            optionalRow("Seekable", d.seekWindowText)
            optionalRow("State", d.playbackStateText)
            row("Buffer", d.bufferStatusText)
            row("Dropped", "\(d.droppedFramesText) frames")
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

    /// Leading numeric token of a formatted value ("24 fps" → "24",
    /// "11.9 Mbps" → "11.9"), or `nil` for the placeholder. Lets a live/observed
    /// value be folded next to its nominal counterpart without repeating the unit.
    private func numericToken(_ text: String) -> String? {
        guard text != PlaybackDiagnostics.placeholder else { return nil }
        return text.split(separator: " ").first.map(String.init)
    }

    /// A nominal value with its live counterpart folded in as "nominal · N live"
    /// (unit shown once). Falls back to the live value alone when there's no
    /// nominal, or the placeholder when neither exists.
    private func withLive(nominal: String, live: String) -> String {
        if nominal != PlaybackDiagnostics.placeholder {
            guard let n = numericToken(live) else { return nominal }
            return "\(nominal) · \(n) live"
        }
        return live
    }

    /// Nominal frame rate with the live observed FPS folded in.
    private func frameRateCombined(_ d: PlaybackDiagnostics) -> String {
        withLive(nominal: d.frameRateText, live: d.observedFpsText)
    }

    /// Indicated (source) video bitrate with the live network bitrate folded in.
    private func videoBitrateCombined(_ d: PlaybackDiagnostics) -> String {
        withLive(nominal: d.indicatedBitrateText, live: d.observedBitrateText)
    }

    /// HDR format folded with its Dolby Vision profile so the HUD shows one HDR
    /// row rather than two overlapping ones.
    private func hdrCombined(_ d: PlaybackDiagnostics) -> String {
        let ph = PlaybackDiagnostics.placeholder
        let hdr = d.hdrText
        let dv = d.dolbyVisionText
        switch (hdr != ph, dv != ph) {
        case (true, true): return "\(hdr) · \(dv)"
        case (true, false): return hdr
        case (false, true): return dv
        case (false, false): return ph
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
