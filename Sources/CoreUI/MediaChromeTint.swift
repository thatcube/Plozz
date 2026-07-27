#if canImport(SwiftUI)
import SwiftUI

/// Whether the card hosting this chrome currently holds focus.
///
/// tvOS cards already track focus with `@FocusState`; they publish it here so the
/// SHARED chrome drawn inside them (the progress bar, the resume chip's text and
/// bar) can dim at rest without each component needing its own focus binding
/// threaded through every call site.
///
/// Always `false` off tvOS, where there is no focus concept — see
/// ``PlozzMediaChrome``, which ignores it there.
private struct PlozzChromeFocusedKey: EnvironmentKey {
    static let defaultValue = false
}

public extension EnvironmentValues {
    var plozzChromeIsFocused: Bool {
        get { self[PlozzChromeFocusedKey.self] }
        set { self[PlozzChromeFocusedKey.self] = newValue }
    }
}

public extension View {
    /// Publishes this card's focus state to the shared media chrome inside it.
    func plozzChromeFocused(_ isFocused: Bool) -> some View {
        environment(\.plozzChromeIsFocused, isFocused)
    }
}

/// The shared white treatment for chrome drawn ON artwork — progress bars, the
/// resume chip's play glyph / time text.
///
/// On **tvOS** a resting card holds this back from pure white, so a wall of cards
/// reads calmly and the focused card's chrome is what pops; focus brings it to
/// full strength. On iOS/iPadOS there is no focus, so it always renders at full
/// strength and these helpers are pass-throughs.
public enum PlozzMediaChrome {
    /// Foreground for text, glyphs and a progress bar's filled portion.
    public static func foreground(isFocused: Bool) -> Color {
        #if os(tvOS)
        isFocused ? .white : .white.opacity(restOpacity)
        #else
        .white
        #endif
    }

    /// The unfilled portion of a progress bar behind ``foreground(isFocused:)``.
    public static func track(isFocused: Bool) -> Color {
        #if os(tvOS)
        .white.opacity(isFocused ? focusedTrackOpacity : restTrackOpacity)
        #else
        .white.opacity(focusedTrackOpacity)
        #endif
    }

    /// Held just below pure white — enough to settle a resting card without
    /// reading as disabled.
    private static let restOpacity: Double = 0.75
    private static let focusedTrackOpacity: Double = 0.32
    private static let restTrackOpacity: Double = 0.24
}
#endif
