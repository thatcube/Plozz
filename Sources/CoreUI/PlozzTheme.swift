#if canImport(SwiftUI)
import SwiftUI

/// Centralised design tokens so spacing/sizing stay consistent and tweakable
/// in one place across all features.
public enum PlozzTheme {
    public enum Metrics {
        /// Standard poster card width (3:2-ish) tuned for tvOS 10-foot UI.
        public static let posterWidth: CGFloat = 280
        public static let posterHeight: CGFloat = 420
        public static let landscapeWidth: CGFloat = 480
        public static let landscapeHeight: CGFloat = 270
        public static let rowSpacing: CGFloat = 40
        public static let cardSpacing: CGFloat = 40
        public static let cornerRadius: CGFloat = 12
        public static let screenPadding: CGFloat = 60
    }
}

#endif
