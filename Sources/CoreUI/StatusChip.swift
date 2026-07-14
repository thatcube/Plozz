#if canImport(SwiftUI)
import SwiftUI

/// A small pill/chip for a short status label (e.g. "Active", "Default", "New").
///
/// Theme- and contrast-aware: the fill is a tinted wash of the chip's accent
/// colour and the text uses the accent itself, so it stays legible on both light
/// and dark settings surfaces without hard-coding foreground/background pairs. A
/// single reusable component so any status pill across the app looks consistent.
public struct StatusChip: View {
    private let text: String
    private let tint: Color

    /// - Parameters:
    ///   - text: The short label (kept to a word or two).
    ///   - tint: The chip's accent colour. Defaults to green ("Active"/positive).
    public init(_ text: String, tint: Color = .green) {
        self.text = text
        self.tint = tint
    }

    @Environment(\.colorScheme) private var colorScheme

    public var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .textCase(.uppercase)
            .tracking(0.5)
            .foregroundStyle(foreground)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous).fill(fill)
            )
            .overlay(
                Capsule(style: .continuous).strokeBorder(tint.opacity(colorScheme == .dark ? 0.35 : 0.25), lineWidth: 1)
            )
            .fixedSize()
    }

    /// A translucent wash of the tint — lighter in dark mode, a touch stronger in
    /// light mode so the pill reads on a white surface.
    private var fill: Color {
        tint.opacity(colorScheme == .dark ? 0.22 : 0.16)
    }

    /// The label colour: the tint itself, darkened slightly in light mode so a
    /// bright accent (e.g. green/yellow) keeps enough contrast on the pale wash.
    private var foreground: Color {
        colorScheme == .dark ? tint : tint.opacity(0.9)
    }
}

#Preview {
    HStack(spacing: 12) {
        StatusChip("Active")
        StatusChip("Default", tint: .blue)
        StatusChip("New", tint: .orange)
    }
    .padding()
}
#endif
