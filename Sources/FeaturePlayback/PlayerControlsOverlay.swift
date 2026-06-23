#if canImport(SwiftUI)
import SwiftUI
import CoreUI

/// The presentational transport overlay for the custom player. Reads
/// `PlayerControlsModel` and draws a title bar, a scrub bar with buffered /
/// played fill, and — while scrubbing — a floating trickplay thumbnail above the
/// scrub head. All input is handled in `PlayerInputViewController`, so this view
/// never takes focus.
struct PlayerControlsOverlay: View {
    let model: PlayerControlsModel
    let palette: ThemePalette

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Spacer(minLength: 0)
            bottomBar
        }
        .opacity(model.controlsVisible ? 1 : 0)
        .animation(.easeInOut(duration: 0.25), value: model.controlsVisible)
        .overlay(alignment: .center) { skipHint }
        .animation(.spring(response: 0.22, dampingFraction: 0.72), value: model.skipHintVisible)
        .animation(.spring(response: 0.22, dampingFraction: 0.72), value: model.skipHintToken)
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    // MARK: Skip hint

    /// Apple-TV-style transient ±10s indicator. A blurred capsule with the
    /// `goforward.10` / `gobackward.10` glyph that pops in and out fast; re-keyed
    /// on `skipHintToken` so rapid repeated skips replay the pop instead of
    /// sitting static.
    @ViewBuilder private var skipHint: some View {
        if model.skipHintVisible {
            Image(systemName: model.skipHintForward ? "goforward.10" : "gobackward.10")
                .font(.system(size: 56, weight: .semibold))
                .foregroundStyle(.white)
                .padding(30)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.12), lineWidth: 1))
                .shadow(radius: 12)
                .id(model.skipHintToken)
                .transition(.scale(scale: 0.5).combined(with: .opacity))
        }
    }

    // MARK: Top

    private var topBar: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.title)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                if !model.subtitle.isEmpty {
                    Text(model.subtitle)
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            Spacer()
            if model.hasSelectableAudio || model.hasSelectableSubtitles {
                Label("Swipe down for options", systemImage: "chevron.down")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(.horizontal, 60)
        .padding(.top, 50)
        .padding(.bottom, 80)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [.black.opacity(0.6), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    // MARK: Bottom

    private var bottomBar: some View {
        VStack(spacing: 14) {
            HStack(spacing: 16) {
                Text(Self.timeLabel(model.displaySeconds))
                    .monospacedDigit()
                    .font(.callout)
                    .foregroundStyle(.white)
                ScrubBar(model: model, palette: palette)
                    .frame(height: 26)
                Text("-" + Self.timeLabel(max(0, model.duration - model.displaySeconds)))
                    .monospacedDigit()
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.8))
                if model.isSeeking {
                    ProgressView()
                        .tint(.white)
                        .frame(width: 28)
                }
            }
        }
        .padding(.horizontal, 60)
        .padding(.bottom, 54)
        .padding(.top, 90)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.7)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
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
}

/// The scrub track: buffered + played fill, a knob, and a floating trickplay
/// thumbnail positioned over the scrub head while scrubbing.
private struct ScrubBar: View {
    let model: PlayerControlsModel
    let palette: ThemePalette

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let knobX = width * CGFloat(model.progressFraction)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.22))
                    .frame(height: 6)
                Capsule()
                    .fill(.white.opacity(0.35))
                    .frame(width: width * CGFloat(model.bufferedFraction), height: 6)
                Capsule()
                    .fill(palette.accent)
                    .frame(width: knobX, height: 6)
                Circle()
                    .fill(.white)
                    .frame(width: model.isScrubbing ? 22 : 16, height: model.isScrubbing ? 22 : 16)
                    .offset(x: knobX - (model.isScrubbing ? 11 : 8))
                    .shadow(radius: 4)

                if model.isScrubbing {
                    thumbnailPreview(width: width, knobX: knobX)
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .animation(.easeOut(duration: 0.12), value: model.isScrubbing)
        }
    }

    @ViewBuilder
    private func thumbnailPreview(width: CGFloat, knobX: CGFloat) -> some View {
        let thumbWidth: CGFloat = 240
        let aspect = previewAspect
        let thumbHeight = thumbWidth / aspect
        let clampedX = min(max(thumbWidth / 2, knobX), width - thumbWidth / 2)

        VStack(spacing: 8) {
            Group {
                if let image = model.previewImage {
                    Image(decorative: image, scale: 1, orientation: .up)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(.black.opacity(0.6))
                }
            }
            .frame(width: thumbWidth, height: thumbHeight)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(.white.opacity(0.85), lineWidth: 2)
            )

            Text(PlayerControlsOverlay.timeLabel(model.scrubSeconds))
                .monospacedDigit()
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .shadow(radius: 3)
        }
        .frame(width: thumbWidth)
        .position(x: clampedX, y: -thumbHeight / 2 - 30)
    }

    private var previewAspect: CGFloat {
        guard let image = model.previewImage, image.height > 0 else { return 16.0 / 9.0 }
        return CGFloat(image.width) / CGFloat(image.height)
    }
}
#endif
