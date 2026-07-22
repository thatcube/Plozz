#if canImport(SwiftUI)
import SwiftUI

extension View {
    /// Applies `.focusSection()` on platforms where it exists (tvOS/macOS) and is a
    /// no-op on iOS/iPadOS, where the modifier is unavailable. Lets the shared
    /// Settings views in this module compile for iPhone/iPad without changing the
    /// tvOS focus-navigation behavior they rely on.
    @ViewBuilder
    func tvOSFocusSection() -> some View {
        #if os(tvOS)
        self.focusSection()
        #else
        self
        #endif
    }

    /// `.focusScope(_:)` on tvOS/macOS; a no-op on iOS/iPadOS.
    @ViewBuilder
    func tvOSFocusScope(_ namespace: Namespace.ID) -> some View {
        #if os(tvOS)
        self.focusScope(namespace)
        #else
        self
        #endif
    }

    /// `.prefersDefaultFocus(_:in:)` on tvOS/macOS; a no-op on iOS/iPadOS.
    @ViewBuilder
    func tvOSPrefersDefaultFocus(_ prefersDefaultFocus: Bool = true, in namespace: Namespace.ID) -> some View {
        #if os(tvOS)
        self.prefersDefaultFocus(prefersDefaultFocus, in: namespace)
        #else
        self
        #endif
    }
}
#endif
