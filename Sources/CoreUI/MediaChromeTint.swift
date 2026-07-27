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
        isFocused ? .white : restForeground
        #else
        .white
        #endif
    }

    /// The unfilled portion of a progress bar behind ``foreground(isFocused:)``.
    public static func track(isFocused: Bool) -> Color {
        #if os(tvOS)
        isFocused ? focusedTrack : restTrack
        #else
        focusedTrack
        #endif
    }

    // The FOREGROUND is opaque on purpose. A translucent glyph or bar fill
    // composites with whatever frame sits behind it, so its contrast changes shot
    // to shot and a bright poster washes it out — the legibility ends up only as
    // good as the artwork. A solid grey reads identically on every card.
    //
    // The TRACK stays translucent, which is the opposite call and deliberate: it
    // is the unfilled remainder, so it should sink into the artwork rather than
    // sit on top of it as a solid bar. Rendered opaque it read as a second,
    // competing element instead of the absence of progress.

    /// Held well below pure white so a resting wall of cards stays calm and the
    /// focused card's chrome is clearly the brightest thing on screen. Safe to sit
    /// this low because it's opaque — it can't be washed out by the poster.
    private static let restForeground = Color(white: 0.72)
    private static let focusedTrack = Color.white.opacity(0.32)
    private static let restTrack = Color.white.opacity(0.24)
}
#endif
