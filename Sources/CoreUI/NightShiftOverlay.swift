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
/// Two things make the tint update *live* rather than only on the next launch:
///  1. It's a plain `UIView` whose `CALayer.backgroundColor` we set directly, not
///     a hosted SwiftUI view. A `UIHostingController` attached straight to the
///     window (outside the view-controller graph, as this must be to float above
///     covers) never gets its SwiftUI update loop driven, so it renders once and
///     then ignores later changes.
///  2. `AppState` rebuilds `nightShiftModel` on every profile switch (which also
///     happens once at launch when the active profile is restored), so the model
///     instance we're handed changes over the app's life. The coordinator
///     re-points at the current instance on every SwiftUI update and re-arms its
///     observation — otherwise it would keep tracking the original, now-dead
///     model, and edits would only appear after a relaunch.

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
        context.coordinator.sync(model: model)
        return probe
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.sync(model: model)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.invalidate()
    }

    @MainActor
    final class Coordinator {
        /// The *current* profile-scoped model. Re-pointed by `sync(model:)`
        /// whenever `AppState` hands us a freshly rebuilt instance.
        private var model: NightShiftSettingsModel
        private var tintView: UIView?
        private var attempts = 0
        private var hasArmed = false
        private var isInvalidated = false
        /// Bumped each time the observation loop is (re)armed so a loop left over
        /// from a previous model instance self-terminates the next time it fires.
        private var observationGeneration = 0

        private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

        init(model: NightShiftSettingsModel) {
            self.model = model
        }

        /// Called on every SwiftUI update with the current model. Attaches the
        /// tint view if needed, and — when the model instance has changed (profile
        /// switch) or we haven't armed yet — re-arms observation against it and
        /// repaints so the new profile's tint shows immediately.
        func sync(model newModel: NightShiftSettingsModel) {
            guard !isInvalidated else { return }
            let changed = newModel !== model
            model = newModel
            installIfNeeded()
            if changed || !hasArmed {
                hasArmed = true
                armObservation()
                paintTint(animated: false)
            }
        }

        private func installIfNeeded() {
            guard !isInvalidated else { return }
            // Already attached to a window — nothing to do.
            if let view = tintView, view.superview != nil { return }

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
        }

        /// Repaints the tint whenever any value the multiply colour derives from
        /// changes. `withObservationTracking` is one-shot, so the change handler
        /// repaints and then re-arms itself; a generation token drops any loop
        /// still bound to a previous model instance.
        private func armObservation() {
            observationGeneration += 1
            let generation = observationGeneration
            let tracked = model
            withObservationTracking {
                // Read the stored inputs directly (so `\.settings`, the preview
                // sweep and the calibration flag all register) plus the derived
                // colour (so the minute `tick` registers via its getter).
                _ = tracked.settings
                _ = tracked.isPreviewing
                _ = tracked.previewDate
                _ = tracked.channelScalars
            } onChange: { [weak self] in
                // `onChange` fires just before the value settles, so hop to the
                // next main-actor turn to read the new value, repaint, and re-arm.
                Task { @MainActor in
                    guard let self, self.observationGeneration == generation else { return }
                    self.paintTint(animated: true)
                    self.armObservation()
                }
            }

        }

        func invalidate() {
            isInvalidated = true
            observationGeneration &+= 1
            hasArmed = false
            tintView?.removeFromSuperview()
            tintView = nil
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
