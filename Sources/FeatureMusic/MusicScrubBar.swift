#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit

/// Observable scrub state shared between the UIKit gesture surface (which writes
/// it) and the SwiftUI bar (which only reads it). Keeping the gesture handling in
/// UIKit is the only reliable way to get **analog** touch-surface scrubbing on
/// tvOS — the SwiftUI `onMoveCommand` API only yields discrete left/right steps,
/// which is what made the first pass feel jagged.
@MainActor
@Observable
final class MusicScrubModel {
    /// Live track length / position, pushed in from the playback controller.
    var duration: TimeInterval = 0
    var currentSeconds: TimeInterval = 0

    /// True while a finger is dragging the scrub head; `scrubSeconds` is the
    /// previewed position. The head follows the finger and ignores live time so
    /// the engine's catch-up never snaps it back.
    var isScrubbing = false
    var scrubSeconds: TimeInterval = 0
    /// Whether the surface owns Siri-Remote focus (drives the bar's grow/glow).
    var isFocused = false

    /// Called on lift with the final scrub destination, so the owner can seek.
    var onCommit: ((TimeInterval) -> Void)?

    /// Where the head renders: the scrub target while scrubbing, else live time.
    var displaySeconds: TimeInterval { isScrubbing ? scrubSeconds : currentSeconds }

    var progressFraction: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, displaySeconds / duration))
    }
}

/// Pure transfer function turning a horizontal pan into scrub movement, with
/// pointer-style acceleration: slow drags stay 1:1 precise, fast flicks fling
/// further along a smoothstep curve. Mirrors the video player's scrubber feel.
private enum MusicScrubGeometry {
    static func accelerationMultiplier(speed: Double) -> Double {
        let onset = 500.0, saturation = 3500.0, maxMultiplier = 5.0
        let t = min(max((speed - onset) / (saturation - onset), 0), 1)
        let smooth = t * t * (3 - 2 * t)
        return 1 + (maxMultiplier - 1) * smooth
    }

    /// Seconds the head moves for one pan sample of `dx` points at `speed` pts/s.
    /// `baseSecondsPerPoint` scales with track length so a swipe covers a similar
    /// *fraction* of any track.
    static func advance(
        scrubSeconds: TimeInterval,
        dx: Double,
        speed: Double,
        duration: TimeInterval
    ) -> TimeInterval {
        let durationScale = min(max(duration / 1800, 0.25), 1.0)
        let baseSecondsPerPoint = 0.18 * durationScale
        let delta = dx * baseSecondsPerPoint * accelerationMultiplier(speed: speed)
        return min(max(0, scrubSeconds + delta), duration)
    }
}

/// A focusable, transparent UIKit surface that captures indirect-touch pans from
/// the Siri Remote and translates them into analog scrubbing. The visible bar is
/// drawn in SwiftUI on top, reading `MusicScrubModel`.
struct MusicScrubSurface: UIViewRepresentable {
    let model: MusicScrubModel
    /// Gates focusability so the surface can't be focused while the transport
    /// controls are hidden. `canBecomeFocused` is UIKit-side and doesn't observe
    /// the SwiftUI opacity that hides the bar, so without this a clickpad
    /// direction press would move focus straight onto the (invisible) scrubber
    /// instead of revealing the controls with the pause button focused.
    var isFocusable: Bool = true

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> FocusableSurfaceView {
        let view = FocusableSurfaceView()
        view.backgroundColor = .clear
        view.isFocusable = isFocusable
        view.onFocusChange = { focused in
            context.coordinator.model.isFocused = focused
        }
        let pan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePan(_:))
        )
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        view.addGestureRecognizer(pan)
        return view
    }

    func updateUIView(_ uiView: FocusableSurfaceView, context: Context) {
        context.coordinator.model = model
        if uiView.isFocusable != isFocusable {
            uiView.isFocusable = isFocusable
            // Drop focus off the surface the moment it's disabled so tvOS doesn't
            // keep it highlighted while the controls slide away.
            if !isFocusable { uiView.setNeedsFocusUpdate() }
        }
    }

    final class FocusableSurfaceView: UIView {
        var onFocusChange: ((Bool) -> Void)?
        var isFocusable: Bool = true
        override var canBecomeFocused: Bool { isFocusable }
        override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
            super.didUpdateFocus(in: context, with: coordinator)
            onFocusChange?(context.nextFocusedView === self)
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var model: MusicScrubModel
        private var lastTranslationX: CGFloat = 0
        private var smoothedSpeed: Double = 0

        init(model: MusicScrubModel) { self.model = model }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard model.duration > 0, let view = gesture.view else { return }
            switch gesture.state {
            case .began:
                model.isScrubbing = true
                model.scrubSeconds = model.currentSeconds
                lastTranslationX = gesture.translation(in: view).x
                smoothedSpeed = 0
            case .changed:
                let translationX = gesture.translation(in: view).x
                let dx = Double(translationX - lastTranslationX)
                lastTranslationX = translationX
                let rawSpeed = abs(Double(gesture.velocity(in: view).x))
                smoothedSpeed += (rawSpeed - smoothedSpeed) * 0.25
                model.scrubSeconds = MusicScrubGeometry.advance(
                    scrubSeconds: model.scrubSeconds,
                    dx: dx,
                    speed: smoothedSpeed,
                    duration: model.duration
                )
            case .ended, .cancelled, .failed:
                if model.isScrubbing {
                    let target = model.scrubSeconds
                    model.onCommit?(target)
                    model.currentSeconds = target
                    model.isScrubbing = false
                }
            default:
                break
            }
        }
    }
}

/// The visible Liquid Glass scrub bar: a glass track, a bright played fill, and a
/// knob that grows when the surface is focused. The `MusicScrubSurface` overlay
/// supplies the analog pan input; the bar itself is purely presentational.
struct MusicScrubBar: View {
    let model: MusicScrubModel
    /// While the control bar is sliding on/off screen, the played fill and knob
    /// must ride that slide as one with the glass track — so suppress the
    /// progress (`knobX`) spring, which would otherwise fire on every playback
    /// tick mid-slide and give the fill/knob a different easing than the track.
    var suppressProgressAnimation: Bool = false
    /// Forwarded to `MusicScrubSurface` so the scrub bar only becomes a focus
    /// target while the transport controls are actually on screen. Without this,
    /// a down-press on the hidden player would land focus on the invisible
    /// scrubber instead of revealing the controls with the pause button focused.
    var isFocusable: Bool = true

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let focused = model.isFocused
            let fraction = max(0, min(1, model.progressFraction))
            let knobX = width * CGFloat(fraction)
            let barHeight: CGFloat = focused ? 18 : 10
            let knobWidth: CGFloat = focused ? 8 : 4
            let knobHeight: CGFloat = focused ? (model.isScrubbing ? 44 : 36) : barHeight

            ZStack(alignment: .leading) {
                glassTrack(height: barHeight)
                UnevenRoundedRectangle(
                    topLeadingRadius: barHeight / 2,
                    bottomLeadingRadius: barHeight / 2,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 0,
                    style: .continuous
                )
                    .fill(.white.opacity(focused ? 0.85 : 0.5))
                    .frame(width: max(knobWidth, knobX), height: barHeight)
                RoundedRectangle(cornerRadius: knobWidth / 2, style: .continuous)
                    .fill(.white)
                    .frame(width: knobWidth, height: knobHeight)
                    .offset(x: knobX - knobWidth / 2)
                    .shadow(radius: 4)
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .animation(.easeOut(duration: 0.18), value: focused)
            .animation(.easeOut(duration: 0.12), value: model.isScrubbing)
            .animation((model.isScrubbing || suppressProgressAnimation) ? nil : .spring(response: 0.34, dampingFraction: 0.85), value: knobX)
            .overlay { MusicScrubSurface(model: model, isFocusable: isFocusable) }
        }
    }

    @ViewBuilder
    private func glassTrack(height: CGFloat) -> some View {
        if #available(tvOS 26.0, *) {
            Capsule()
                .fill(.clear)
                .frame(height: height)
                .glassEffect(.regular, in: Capsule())
        } else {
            Capsule()
                .fill(.white.opacity(0.22))
                .frame(height: height)
        }
    }
}
#endif
