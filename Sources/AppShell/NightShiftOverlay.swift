#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit
import CoreModels

/// Installs Night Shift's tint so it floats above *everything* — including the
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

// MARK: - Tint view

/// The SwiftUI content hosted in the overlay: one opaque rectangle filled with
/// the model's current multiply colour. The host view's layer multiplies it
/// against the app (see the installer), so this colour acts as a per-channel
/// scale — white by day (×1, invisible), redder as night deepens.
private struct NightShiftTintView: View {
    var model: NightShiftSettingsModel

    private var multiplyColor: Color {
        let s = model.channelScalars
        return Color(.sRGB, red: s.red, green: s.green, blue: s.blue, opacity: 1)
    }

    var body: some View {
        Rectangle()
            .fill(multiplyColor)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .animation(.easeInOut(duration: 0.6), value: model.currentDimOpacity)
            .animation(.easeInOut(duration: 0.6), value: model.currentWarmOpacity)
    }
}

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
        private var hostingController: UIHostingController<NightShiftTintView>?
        private var attempts = 0

        init(model: NightShiftSettingsModel) {
            self.model = model
        }

        func installIfNeeded() {
            // Already attached to a window — nothing to do.
            if let view = hostingController?.view, view.superview != nil { return }

            guard let window = Self.mainWindow() else {
                // The window can lag the first few layout passes — retry briefly.
                attempts += 1
                guard attempts < 60 else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    self?.installIfNeeded()
                }
                return
            }

            let host = hostingController
                ?? UIHostingController(rootView: NightShiftTintView(model: model))
            hostingController = host

            guard let view = host.view else { return }
            view.backgroundColor = .clear
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
    /// Attaches the global Night Shift tint to the app's main window.
    public func installNightShiftOverlay(_ model: NightShiftSettingsModel) -> some View {
        background(NightShiftOverlayInstaller(model: model))
    }
}
#endif
