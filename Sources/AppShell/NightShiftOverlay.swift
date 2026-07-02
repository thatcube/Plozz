#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit
import Observation
import CoreModels

/// Installs Circadian Mode's tint so it floats above *everything* — including the
/// player and other `fullScreenCover`s — without ever stealing focus, and tints
/// by **multiplying** the app rather than painting a wash on top.
///
/// Why multiply, and why it must live in the app's own window: a real
/// colour-temperature filter (and the system's Color Filters) multiplies the
/// screen — it scales the green/blue channels down to redden the picture while
/// leaving red (and therefore black) untouched, so nothing is brightened.
/// Source-over compositing can't do that; it always lifts dark pixels toward the
/// tint colour, which reads as a bright orange/red glow. Core Animation honours a
/// `multiplyBlendMode` compositing filter only when the tint layer composites
/// *within the same window* as the content — tvOS's window server ignores it
/// across separate windows. So instead of a dedicated overlay window, we add a
/// passthrough tint view directly into the app's main window and push it to the
/// front with a very high `zPosition`, which keeps it above the modally-presented
/// covers (player, etc.) that are sibling subviews of that same window.
///
/// The tint is a plain `UIView` whose `CALayer.backgroundColor` we set directly,
/// *not* a hosted SwiftUI view. A `UIHostingController` attached straight to the
/// window (outside the view-controller graph, as this must be to float above
/// covers) never gets its SwiftUI update loop driven, so it renders once at
/// launch and then ignores later `@Observable` changes — the tint would only
/// refresh on the next launch. Painting the layer colour ourselves, driven by an
/// explicit observation loop, repaints reliably the instant warmth/darkness/
/// schedule change.

// MARK: - Installer

/// Adds the tint view to the active window once a window is available and keeps it
/// alive for the app's lifetime. It lives as a hidden representable inside the
/// root view purely so SwiftUI gives it a lifecycle hook; the actual tint view is
/// attached to the main window, retrying until the window has connected (the
/// scene is often not ready on the very first layout pass).
private struct NightShiftOverlayInstaller: UIViewRepresentable {
    var model: NightShiftSettingsModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> UIView {
        let probe = UIView(frame: .zero)
        probe.isHidden = true
        context.coordinator.installIfNeeded()
        return probe
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.installIfNeeded()
    }

    @MainActor
    final class Coordinator {
        private let model: NightShiftSettingsModel
        private var tintView: UIView?
        private var attempts = 0
        /// The tint lives straight on the `UIWindow`, so SwiftUI's implicit
        /// `@Observable` tracking never re-runs against it. We drive repaints
        /// ourselves with `withObservationTracking`; without this loop a live
        /// warmth/darkness/schedule change would only take effect next launch.
        private var isObserving = false

        private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

        init(model: NightShiftSettingsModel) {
            self.model = model
        }

        func installIfNeeded() {
            // Already attached to a window — just make sure it shows the current
            // colour (e.g. after the model instance was swapped on a profile
            // switch) and keep it frontmost.
            if let view = tintView, view.superview != nil {
                paintTint(animated: false)
                return
            }

            guard let window = Self.mainWindow() else {
                // The window can lag the first few layout passes — retry briefly.
                attempts += 1
                guard attempts < 60 else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    self?.installIfNeeded()
                }
                return
            }

            let view = tintView ?? UIView(frame: window.bounds)
            tintView = view
            view.isUserInteractionEnabled = false
            view.frame = window.bounds
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            // Multiply the tint against everything below it *within this window*
            // (the one place tvOS honours the filter). A maximal zPosition keeps
            // it drawing last — above any fullScreenCover presented later, which
            // are sibling subviews of this same window.
            view.layer.compositingFilter = "multiplyBlendMode"
            view.layer.zPosition = .greatestFiniteMagnitude

            window.addSubview(view)
            paintTint(animated: false)
            startObservingModel()
        }

        /// Repaints the tint whenever any value the multiply colour derives from
        /// changes. `withObservationTracking` is one-shot, so the change handler
        /// repaints and then re-arms itself for the next change.
        private func startObservingModel() {
            guard !isObserving else { return }
            isObserving = true
            observeTintOnce()
        }

        private func observeTintOnce() {
            withObservationTracking {
                // Read the stored inputs directly (so `\.settings`, the preview
                // sweep and the calibration flag all register) plus the derived
                // colour (so the minute `tick` registers via its getter).
                _ = model.settings
                _ = model.isPreviewing
                _ = model.previewDate
                _ = model.channelScalars
            } onChange: { [weak self] in
                // `onChange` fires just before the value settles, so hop to the
                // next main-actor turn to read the new value, repaint, and re-arm.
                Task { @MainActor in
                    guard let self else { return }
                    self.paintTint(animated: true)
                    self.observeTintOnce()
                }
            }
        }

        /// Sets the tint layer's colour to the model's current per-channel
        /// multiply (white by day → invisible, redder as night deepens),
        /// optionally easing from wherever it is now.
        private func paintTint(animated: Bool) {
            guard let view = tintView else { return }
            let scalars = model.channelScalars
            let target = CGColor(
                colorSpace: Self.colorSpace,
                components: [
                    CGFloat(scalars.red),
                    CGFloat(scalars.green),
                    CGFloat(scalars.blue),
                    1,
                ]
            ) ?? UIColor(
                red: CGFloat(scalars.red),
                green: CGFloat(scalars.green),
                blue: CGFloat(scalars.blue),
                alpha: 1
            ).cgColor

            if animated {
                let animation = CABasicAnimation(keyPath: "backgroundColor")
                // Chase from the on-screen colour so rapid updates (the day
                // preview sweep) glide instead of snapping.
                animation.fromValue = view.layer.presentation()?.backgroundColor
                    ?? view.layer.backgroundColor
                    ?? target
                animation.toValue = target
                animation.duration = 0.6
                animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                view.layer.add(animation, forKey: "tint")
            }
            view.layer.backgroundColor = target
        }

        private static func mainWindow() -> UIWindow? {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            guard let scene = scenes.first(where: { $0.activationState == .foregroundActive })
                ?? scenes.first else { return nil }
            return scene.windows.first { $0.isKeyWindow } ?? scene.windows.first
        }
    }
}

extension View {
    /// Attaches the global Circadian Mode tint to the app's main window.
    public func installNightShiftOverlay(_ model: NightShiftSettingsModel) -> some View {
        background(NightShiftOverlayInstaller(model: model))
    }
}
#endif
