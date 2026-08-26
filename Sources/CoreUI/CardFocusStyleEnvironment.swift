#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// The active profile's `CardFocusStyle`, injected into the SwiftUI environment
/// at the app root (see `RootView`) alongside `\.plozzCardStyle`. Every focusable
/// media card reads this, so turning the focus outline off restyles the whole
/// media UI live with no view rebuild — exactly like the theme palette, the
/// density metrics and the card style.
private struct PlozzCardFocusStyleKey: EnvironmentKey {
    static let defaultValue: CardFocusStyle = .default
}

public extension EnvironmentValues {
    /// The live, per-profile card focus treatment (glass outline vs the native
    /// grow-and-glisten highlight). Set once at the app root; read by
    /// `plozzCardFocusLift`, `plozzCardFocusTransition` and `plozzFocusHalo`.
    var plozzCardFocusStyle: CardFocusStyle {
        get { self[PlozzCardFocusStyleKey.self] }
        set { self[PlozzCardFocusStyleKey.self] = newValue }
    }
}
#endif
