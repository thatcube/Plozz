#if canImport(SwiftUI) && canImport(AVFoundation)
import SwiftUI
import CoreModels
import CoreUI

/// The full-screen Now Playing surface: large artwork, track/artist/album, a
/// quality badge, a full-width analog Liquid Glass scrub bar with the play/pause
/// button beside it, and a row of equally-sized Liquid Glass transport buttons
/// below. Single centered column — no Up Next list. Observes the shared
/// `AudioPlaybackController`.
struct NowPlayingView: View {
    @Bindable var controller: AudioPlaybackController
    @Environment(\.dismiss) private var dismiss
    @State private var scrubModel = MusicScrubModel()

    /// Whether the user wants the lyrics panel shown. Persisted (default on) so
    /// the choice is remembered across sessions. The toggle is disabled — and so
    /// can't be changed — when the current track has no lyrics.
    @AppStorage("musicLyricsEnabled") private var lyricsEnabled = true

    /// Uniform size for every transport control so the row reads evenly.
    private let controlSize: CGFloat = 64

    /// The lyrics panel is shown next to the player whenever the user has lyrics
    /// enabled and something is playing. It renders its own loading / found /
    /// "No lyrics found" states, so even an empty result is visible (debug-friendly).
    private var showsLyricsPanel: Bool {
        lyricsEnabled && controller.currentTrack != nil && controller.lyricsState != .idle
    }

    var body: some View {
        ZStack {
            background
            HStack(alignment: .center, spacing: 56) {
                playerColumn
                    .frame(maxWidth: showsLyricsPanel ? 760 : 960)
                if showsLyricsPanel {
                    NowPlayingLyricsView(
                        state: controller.lyricsState,
                        currentTime: controller.currentTime
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 60)
            .animation(.easeInOut(duration: 0.25), value: showsLyricsPanel)
        }
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.title2)
                    .padding(24)
            }
            .buttonStyle(.plain)
            .padding(32)
        }
        .onAppear { syncScrubModel() }
        .onChange(of: controller.currentTime) { _, _ in syncScrubModel() }
        .onChange(of: controller.duration) { _, _ in syncScrubModel() }
    }

    /// The left-hand player column: artwork, track/artist/album, quality badge,
    /// scrub bar with play/pause, and the transport + lyrics-toggle row.
    private var playerColumn: some View {
        VStack(spacing: 36) {
            MusicArtworkImage(
                url: controller.currentTrack?.artworkURL,
                systemPlaceholder: "music.note",
                asyncFallbackURL: trackFallback(controller.currentTrack)
            )
                .frame(width: 420, height: 420)
                .shadow(radius: 30)

            VStack(spacing: 8) {
                Text(controller.currentTrack?.title ?? "Not Playing")
                    .font(.system(size: 46, weight: .bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .shadow(color: .black.opacity(0.4), radius: 8, y: 2)
                if let subtitle = controller.currentTrack?.subtitle {
                    Text(subtitle)
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                }
                qualityBadge
            }

            scrubRow
            transportRow
        }
    }

    private func syncScrubModel() {
        scrubModel.duration = controller.duration
        if !scrubModel.isScrubbing { scrubModel.currentSeconds = controller.currentTime }
        scrubModel.onCommit = { target in
            Task { await controller.seek(to: target) }
        }
    }

    @ViewBuilder
    private var background: some View {
        if let track = controller.currentTrack {
            FallbackAsyncImage(
                urls: [track.artworkURL].compactMap { $0 },
                asyncFallbackURL: MusicArtworkFallback.artistImage(name: track.artistName ?? "")
            ) {
                Color.black
            }
            .ignoresSafeArea()
            .overlay(.ultraThinMaterial)
            .overlay(Color.black.opacity(0.35))
        } else {
            Color.black.ignoresSafeArea()
        }
    }

    @ViewBuilder
    private var qualityBadge: some View {
        if let quality = controller.currentQuality {
            HStack(spacing: 10) {
                Image(systemName: quality.isDirectPlay ? "waveform" : "arrow.triangle.2.circlepath")
                    .font(.headline)
                Text(quality.headline)
                    .font(.headline)
                if let detail = quality.detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(qualityTint.opacity(0.6), lineWidth: 1))
            .foregroundStyle(qualityTint)
            .padding(.top, 4)
        }
    }

    private var qualityTint: Color {
        guard let quality = controller.currentQuality else { return .secondary }
        if !quality.isDirectPlay { return .orange }
        return quality.isLossless ? .green : .primary
    }

    /// Play/pause beside a full-width analog scrub bar (+ elapsed/remaining times).
    private var scrubRow: some View {
        HStack(spacing: 28) {
            transportButton(
                icon: controller.isPlaying ? "pause.fill" : "play.fill",
                prominent: true
            ) { controller.togglePlayPause() }

            VStack(spacing: 10) {
                MusicScrubBar(model: scrubModel)
                    .frame(height: 44)
                HStack {
                    Text(MusicFormat.duration(scrubModel.displaySeconds))
                    Spacer()
                    Text(MusicFormat.duration(controller.duration))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
    }

    /// Every other control, evenly sized, on the row below. Includes the lyrics
    /// toggle, which is disabled when the current track has no lyrics.
    private var transportRow: some View {
        HStack(spacing: 28) {
            transportButton(
                icon: "shuffle",
                prominent: controller.isShuffled,
                tint: controller.isShuffled ? Color.accentColor : .primary
            ) { controller.toggleShuffle() }

            transportButton(icon: "backward.fill") { controller.previous() }
            transportButton(icon: "forward.fill") { controller.next() }

            transportButton(
                icon: repeatIcon,
                prominent: controller.repeatMode != .off,
                tint: controller.repeatMode == .off ? .primary : Color.accentColor
            ) { controller.cycleRepeatMode() }

            lyricsToggleButton
        }
    }

    /// Toggles the lyrics panel. Highlighted when on; disabled (and dimmed) while
    /// the current track has no lyrics, so it can't be turned on for nothing.
    private var lyricsToggleButton: some View {
        let hasLyrics = controller.lyricsState.hasLyrics
        return transportButton(
            icon: lyricsEnabled ? "quote.bubble.fill" : "quote.bubble",
            prominent: lyricsEnabled && hasLyrics,
            tint: (lyricsEnabled && hasLyrics) ? Color.accentColor : .primary
        ) {
            lyricsEnabled.toggle()
        }
        .disabled(!hasLyrics)
        .opacity(hasLyrics ? 1 : 0.4)
    }

    private func transportButton(
        icon: String,
        prominent: Bool = false,
        tint: Color = .primary,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: controlSize, height: controlSize)
        }
        .musicGlassButton(prominent: prominent)
    }

    private var repeatIcon: String {
        switch controller.repeatMode {
        case .off, .all: return "repeat"
        case .one: return "repeat.1"
        }
    }

    /// Best-effort album-cover fallback for `track`, used only when the server
    /// ships no artwork. `nil` track / blank fields yield no fallback.
    private func trackFallback(_ track: MusicTrack?) -> (@Sendable () async -> URL?)? {
        guard let track else { return nil }
        return MusicArtworkFallback.trackCover(
            title: track.title,
            album: track.albumTitle,
            artist: track.artistName
        )
    }
}

// MARK: - Lyrics panel

/// The right-hand lyrics column on the Now Playing screen. Renders the loading
/// state, the lyrics themselves (synced lyrics highlight + auto-scroll the active
/// line; plain lyrics just scroll), or a debug "No lyrics found" placeholder when
/// the track has none.
struct NowPlayingLyricsView: View {
    let state: AudioPlaybackController.LyricsState
    let currentTime: TimeInterval

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .firstTextBaseline) {
                Text("Lyrics")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if case let .loaded(lyrics) = state, let source = lyrics.source {
                    LyricsSourceBadge(source: source)
                }
            }

            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(40)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle, .loading:
            VStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .unavailable:
            VStack(alignment: .leading) {
                Spacer()
                Text("No lyrics found")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

        case let .loaded(lyrics):
            lyricsScroll(lyrics)
        }
    }

    private func lyricsScroll(_ lyrics: Lyrics) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { index, line in
                        let active = isActive(index: index, in: lyrics)
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(.system(size: 30, weight: active ? .bold : .regular))
                            .foregroundStyle(active ? .primary : .secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                            .animation(.easeInOut(duration: 0.2), value: active)
                    }
                }
                .padding(.vertical, 8)
            }
            .onChange(of: activeIndex(in: lyrics)) { _, newIndex in
                guard lyrics.isSynced, let newIndex else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
        }
    }

    /// The index of the line currently being sung, for synced lyrics.
    private func activeIndex(in lyrics: Lyrics) -> Int? {
        guard lyrics.isSynced else { return nil }
        var match: Int?
        for (index, line) in lyrics.lines.enumerated() {
            guard let start = line.start else { continue }
            if start <= currentTime { match = index } else { break }
        }
        return match
    }

    private func isActive(index: Int, in lyrics: Lyrics) -> Bool {
        activeIndex(in: lyrics) == index
    }
}

/// Tiny attribution shown in the lyrics panel header: the source's brand mark
/// (the same app-bundle logos used in Settings for Jellyfin/Plex) plus its name.
/// LRCLIB has no bundled logo, so it uses an SF Symbol stand-in.
struct LyricsSourceBadge: View {
    let source: LyricsSource

    var body: some View {
        HStack(spacing: 6) {
            logo
            Text(source.displayName)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(.tertiary)
    }

    @ViewBuilder
    private var logo: some View {
        switch source {
        case .jellyfin:
            Image("JellyfinLogo").renderingMode(.template).resizable().scaledToFit().frame(width: 16, height: 16)
        case .plex:
            Image("PlexLogo").renderingMode(.template).resizable().scaledToFit().frame(width: 16, height: 16)
        case .lrclib:
            Image(systemName: "quote.bubble").font(.caption)
        }
    }
}

private extension View {
    /// The system Liquid Glass button style (tvOS 26+), falling back to the
    /// bordered styles on older systems. `prominent` highlights play/active toggles.
    @ViewBuilder
    func musicGlassButton(prominent: Bool) -> some View {
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
