#if canImport(SwiftUI)
import SwiftUI
import CoreModels

public extension SubtitleColor {
    /// The SwiftUI `Color` for this neutral subtitle colour. Lives in `CoreUI`
    /// because it needs SwiftUI; the CoreMedia `argbArray` bridge lives in
    /// `CoreModels` next to the pure data.
    var swiftUIColor: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}
#endif
