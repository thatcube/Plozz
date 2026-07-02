#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// A reusable, focus-friendly grid of "what Plozz can do" cards rendered from a
/// data-driven `[OnboardingHighlight]`. Pure presentation — no gating or
/// persistence — so both the first-run `WelcomeView` (AppShell) and the Settings
/// "What Plozz Can Do" page share one rendering and never drift.
///
/// Cards are focusable (but not buttons): the Siri Remote can pan across them and
/// the focus engine auto-scrolls a longer list into view, without implying a tap
/// action that doesn't exist. Theme-aware via `\.themePalette`.
public struct OnboardingHighlightsView: View {
    private let highlights: [OnboardingHighlight]
    private let columns: Int

    public init(
        highlights: [OnboardingHighlight] = OnboardingHighlight.defaultHighlights,
        columns: Int = 2
    ) {
        self.highlights = highlights
        self.columns = max(1, columns)
    }

    public var body: some View {
        let gridColumns = Array(
            repeating: GridItem(.flexible(), spacing: 28, alignment: .top),
            count: columns
        )
        LazyVGrid(columns: gridColumns, spacing: 28) {
            ForEach(highlights) { highlight in
                OnboardingHighlightCard(highlight: highlight)
            }
        }
    }
}

/// One informational highlight card: an accent-tinted glyph badge beside a
/// benefit headline and a short explanatory line, on the shared liquid-glass
/// surface. Focusable so the remote can move across the grid.
private struct OnboardingHighlightCard: View {
    let highlight: OnboardingHighlight

    @Environment(\.themePalette) private var palette
    @FocusState private var isFocused: Bool

    private let cornerRadius: CGFloat = 24

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            iconBadge
            VStack(alignment: .leading, spacing: 10) {
                Text(highlight.title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(palette.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Text(highlight.message)
                    .font(.callout)
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(30)
        .frame(maxWidth: .infinity, minHeight: 210, alignment: .topLeading)
        .plozzGlassCard(cornerRadius: cornerRadius, isFocused: isFocused)
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    isFocused ? palette.accent.opacity(0.9) : Color.clear,
                    lineWidth: isFocused ? 5 : 0
                )
        }
        .shadow(color: .black.opacity(isFocused ? 0.3 : 0), radius: 16, y: 8)
        .scaleEffect(isFocused ? 1.03 : 1)
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .zIndex(isFocused ? 2 : 0)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(highlight.title). \(highlight.message)")
        .animation(.easeOut(duration: 0.18), value: isFocused)
    }

    private var iconBadge: some View {
        ZStack {
            Circle().fill(palette.accent.opacity(0.18))
            Image(systemName: highlight.symbol)
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(palette.accent)
        }
        .frame(width: 80, height: 80)
    }
}

#endif
