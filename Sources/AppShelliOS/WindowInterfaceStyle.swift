#if canImport(UIKit)
import SwiftUI
import UIKit

/// Forces the host `UIWindow`'s `overrideUserInterfaceStyle` to match the app's
/// chosen theme.
///
/// SwiftUI's `.preferredColorScheme` styles the SwiftUI view tree, but UIKit
/// *system-presented* chrome — `Menu` popovers, `.contextMenu`, alerts, action
/// sheets — is rendered by UIKit against the **window/system** appearance, not the
/// SwiftUI environment. So when the app is forced to Dark/OLED while the device is
/// in Light mode, those menus come up light (white background, black text) over
/// the dark app. Pinning the window's `overrideUserInterfaceStyle` makes every
/// system-presented surface follow the app theme too.
private struct WindowInterfaceStyleModifier: ViewModifier {
    let isLight: Bool

    func body(content: Content) -> some View {
        content.background(WindowInterfaceStyleApplier(style: isLight ? .light : .dark))
    }
}

private struct WindowInterfaceStyleApplier: UIViewRepresentable {
    let style: UIUserInterfaceStyle

    func makeUIView(context: Context) -> StyleApplierView {
        StyleApplierView(style: style)
    }

    func updateUIView(_ uiView: StyleApplierView, context: Context) {
        uiView.apply(style)
    }

    final class StyleApplierView: UIView {
        private var style: UIUserInterfaceStyle

        init(style: UIUserInterfaceStyle) {
            self.style = style
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func apply(_ style: UIUserInterfaceStyle) {
            self.style = style
            window?.overrideUserInterfaceStyle = style
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            window?.overrideUserInterfaceStyle = style
        }
    }
}

extension View {
    /// Pins the host window's interface style to the app theme so UIKit-presented
    /// menus/alerts/popovers match it. Pass `isLight` from the resolved palette.
    func syncsWindowInterfaceStyle(isLight: Bool) -> some View {
        modifier(WindowInterfaceStyleModifier(isLight: isLight))
    }
}
#endif
