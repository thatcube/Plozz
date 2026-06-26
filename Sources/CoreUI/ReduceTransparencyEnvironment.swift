#if canImport(SwiftUI)
import SwiftUI

/// Effective "reduce transparency" for Plozz's liquid-glass surfaces.
///
/// SwiftUI's `\.accessibilityReduceTransparency` is read-only, so the app can't
/// override it to honour an in-app preference. This writable key carries the
/// **effective** value — the OS Accessibility setting OR the in-app
/// Settings ▸ Appearance "Reduce transparency" toggle — injected once at the app
/// root (`RootView`). Every glass card/panel/control reads this instead of the
/// system key so the toggle (and the OS setting) both switch them to solid
/// surfaces. Defaults to `false` outside the root (e.g. SwiftUI previews); the
/// real UI tree always receives the root's injected value.
private struct PlozzReduceTransparencyKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

public extension EnvironmentValues {
    var plozzReduceTransparency: Bool {
        get { self[PlozzReduceTransparencyKey.self] }
        set { self[PlozzReduceTransparencyKey.self] = newValue }
    }
}
#endif
