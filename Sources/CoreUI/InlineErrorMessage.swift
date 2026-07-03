#if canImport(SwiftUI)
import SwiftUI

/// A shared inline error line: a warning triangle followed by a short message,
/// tinted with the active theme's `errorText` colour so it reads as a clear
/// error in every theme (brighter on dark/OLED, deeper on light). Use anywhere
/// the UI needs to surface a recoverable failure (wrong credentials, server
/// unreachable, etc.) rather than hand-rolling a red `Label` each time.
public struct InlineErrorMessage: View {
    @Environment(\.themePalette) private var palette

    private let message: LocalizedStringKey
    private let systemImage: String

    public init(
        _ message: LocalizedStringKey,
        systemImage: String = "exclamationmark.triangle.fill"
    ) {
        self.message = message
        self.systemImage = systemImage
    }

    public var body: some View {
        Label {
            Text(message)
        } icon: {
            Image(systemName: systemImage)
        }
        .foregroundStyle(palette.errorText)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
