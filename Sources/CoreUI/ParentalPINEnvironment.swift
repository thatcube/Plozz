#if canImport(SwiftUI)
import SwiftUI

/// Whether the household has a Parental PIN.
///
/// Carried in the environment rather than threaded through initializers: the
/// settings tree is deep and its root initializer already takes ~60 arguments,
/// which the type-checker refuses past a point. Every surface that has to decide
/// between "Kids Profile is curation" and "Kids Profile is enforced" reads it
/// from one place, so they can't disagree.
private struct PlozzHasParentalPINKey: EnvironmentKey {
    /// No PIN by default, so a screen that forgets to inject it fails toward
    /// *showing* the settings rather than locking someone out of their own app.
    static let defaultValue: Bool = false
}

public extension EnvironmentValues {
    var plozzHasParentalPIN: Bool {
        get { self[PlozzHasParentalPINKey.self] }
        set { self[PlozzHasParentalPINKey.self] = newValue }
    }
}
#endif
