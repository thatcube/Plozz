#if canImport(SwiftUI)
import SwiftUI

public extension Font {
    /// A high-legibility font for one-time codes (Quick Connect, Plex link,
    /// Trakt device code, …).
    ///
    /// Uses the monospaced system face (SF Mono), whose **dotted zero** makes
    /// `0` unmistakable from `O` and `1`/`I`/`l` distinct — important when a user
    /// has to read a code off the TV and type it on another device. Every place
    /// that shows a user-entered code should use this instead of a proportional
    /// or rounded face.
    static func plozzCode(size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}
#endif
