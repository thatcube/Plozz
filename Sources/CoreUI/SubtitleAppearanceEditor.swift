#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// The one shared subtitle **appearance** editor, binding a ``SubtitleStyle``.
///
/// Presets-first (a row of curated starting points), then an *Advanced*
/// disclosure exposing the individual knobs (size, position, colour, opacity,
/// background box, edge treatment, and the follow-system escape hatch). Every
/// control is a focusable `Button`/`Toggle` so it drives cleanly with the Siri
/// Remote, and a compact preview strip sits on top so the look is legible even
/// when no subtitle is currently on screen.
///
/// It is intentionally framework-light and lives in `CoreUI` (next to
/// ``SubtitleColor/swiftUIColor``) so the same editor can be hosted over live
/// video in the player today and reused elsewhere later. Edits flow straight
/// through the `@Binding`; the host decides what that means (the player routes
/// each change to the live overlay **and** persistence).
public struct SubtitleAppearanceEditor: View {
    @Binding private var style: SubtitleStyle
    @State private var showAdvanced = false

    public init(style: Binding<SubtitleStyle>) {
        self._style = style
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            previewStrip

            sectionLabel("Presets")
            presetsRow

            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showAdvanced.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "slider.horizontal.3")
                    Text("Advanced")
                    Spacer(minLength: 8)
                    Image(systemName: showAdvanced ? "chevron.up" : "chevron.down")
                        .font(.footnote.weight(.semibold))
                }
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showAdvanced {
                advancedKnobs
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: Preview

    /// A small sample line so the current look is visible even between cues.
    /// The player renders the *real* preview on the live video behind this panel;
    /// this is the always-there fallback and a fast at-a-glance confirmation.
    private var previewStrip: some View {
        ZStack {
            LinearGradient(
                colors: [Color.gray.opacity(0.55), Color.black.opacity(0.9)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            sampleText
        }
        .frame(maxWidth: .infinity)
        .frame(height: 96)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
    }

    private var sampleText: some View {
        let follows = style.followsSystemStyle
        let fg: Color = follows ? .white : style.textColor.swiftUIColor
        return Text("The quick brown fox")
            .font(.system(size: 22 * clampedScale, weight: .semibold))
            .foregroundStyle(fg)
            .padding(.horizontal, style.background.isEnabled && !follows ? 12 : 0)
            .padding(.vertical, style.background.isEnabled && !follows ? 6 : 0)
            .background {
                if style.background.isEnabled && !follows {
                    RoundedRectangle(cornerRadius: style.background.cornerRadius, style: .continuous)
                        .fill(style.background.color.swiftUIColor)
                }
            }
            .shadow(color: previewShadowColor, radius: previewShadowRadius, x: 0, y: 1)
            .opacity(follows ? 1 : style.opacity)
    }

    private var previewShadowColor: Color {
        switch style.edge.style {
        case .none: return .clear
        default: return style.edge.color.swiftUIColor
        }
    }

    private var previewShadowRadius: CGFloat {
        style.edge.style == .none ? 0 : max(1, CGFloat(style.edge.thickness))
    }

    private var clampedScale: CGFloat { CGFloat(min(max(style.fontScale, 0.5), 2.0)) }

    // MARK: Presets

    private var presetsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(SubtitleStyle.presets) { preset in
                    Button {
                        applyPreset(preset.style)
                    } label: {
                        Text(preset.name)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.card)
                }
            }
            .padding(.vertical, 2)
        }
    }

    /// Apply a preset's *look* (colour / background / edge / border) while
    /// preserving the viewer's own size & placement — those axes are orthogonal
    /// to the preset's visual identity, so tapping "Boxed" shouldn't yank the
    /// subtitles back to the default size or reset a nudged position.
    private func applyPreset(_ preset: SubtitleStyle) {
        var next = preset
        next.fontScale = style.fontScale
        next.verticalPosition = style.verticalPosition
        next.horizontalOffset = style.horizontalOffset
        next.opacity = style.opacity
        next.fontFamily = style.fontFamily
        next.followsSystemStyle = style.followsSystemStyle
        style = next
    }

    // MARK: Advanced knobs

    @ViewBuilder
    private var advancedKnobs: some View {
        VStack(alignment: .leading, spacing: 6) {
            toggleRow("Use System Style", isOn: Binding(
                get: { style.followsSystemStyle },
                set: { style.followsSystemStyle = $0 }
            ))

            if !style.followsSystemStyle {
                Divider().background(.white.opacity(0.1))

                adjustRow(
                    "Text Size",
                    value: "\(Int((style.fontScale * 100).rounded()))%",
                    onDecrement: { setScale(style.fontScale - 0.1) },
                    onIncrement: { setScale(style.fontScale + 0.1) }
                )

                adjustRow(
                    "Position",
                    value: positionLabel,
                    onDecrement: { setPosition(style.verticalPosition - 0.05) },
                    onIncrement: { setPosition(style.verticalPosition + 0.05) }
                )

                adjustRow(
                    "Opacity",
                    value: "\(Int((style.opacity * 100).rounded()))%",
                    onDecrement: { setOpacity(style.opacity - 0.1) },
                    onIncrement: { setOpacity(style.opacity + 0.1) }
                )

                cycleRow(
                    "Text Colour",
                    value: colorName(style.textColor),
                    swatch: style.textColor
                ) { cycleTextColor() }

                cycleRow(
                    "Outline",
                    value: style.edge.style.displayName,
                    swatch: nil
                ) { cycleEdgeStyle() }

                toggleRow("Background Box", isOn: Binding(
                    get: { style.background.isEnabled },
                    set: { style.background.isEnabled = $0 }
                ))

                if style.background.isEnabled {
                    cycleRow(
                        "Box Colour",
                        value: colorName(style.background.color),
                        swatch: style.background.color
                    ) { cycleBackgroundColor() }
                }
            }
        }
    }

    // MARK: Knob mutations (each clamps, then writes the whole style through the binding)

    private func setScale(_ v: Double) { style.fontScale = (min(max(v, 0.5), 2.0) * 10).rounded() / 10 }
    private func setPosition(_ v: Double) { style.verticalPosition = (min(max(v, 0.0), 0.5) * 100).rounded() / 100 }
    private func setOpacity(_ v: Double) { style.opacity = (min(max(v, 0.3), 1.0) * 10).rounded() / 10 }

    private func cycleTextColor() {
        style.textColor = nextColor(after: style.textColor, in: SubtitleColor.presets.map(\.color))
    }

    private func cycleBackgroundColor() {
        style.background.color = nextColor(after: style.background.color, in: Self.boxColors)
    }

    private func cycleEdgeStyle() {
        let all = SubtitleEdgeStyle.allCases
        let idx = all.firstIndex(of: style.edge.style) ?? 0
        style.edge.style = all[(idx + 1) % all.count]
    }

    private func nextColor(after current: SubtitleColor, in palette: [SubtitleColor]) -> SubtitleColor {
        guard !palette.isEmpty else { return current }
        let idx = palette.firstIndex(of: current) ?? -1
        return palette[(idx + 1) % palette.count]
    }

    /// Box fills carry their own alpha so the background reads as a translucent
    /// plate rather than an opaque block.
    private static let boxColors: [SubtitleColor] = [
        SubtitleColor(red: 0, green: 0, blue: 0, alpha: 0.65),
        SubtitleColor(red: 0.15, green: 0.15, blue: 0.15, alpha: 0.7),
        SubtitleColor(red: 1, green: 1, blue: 1, alpha: 0.75)
    ]

    private func colorName(_ color: SubtitleColor) -> String {
        if let named = SubtitleColor.presets.first(where: { $0.color == color })?.name { return named }
        if let boxIdx = Self.boxColors.firstIndex(of: color) {
            return ["Black", "Charcoal", "White"][boxIdx]
        }
        return "Custom"
    }

    private var positionLabel: String {
        switch style.verticalPosition {
        case ..<0.03: return "Lowest"
        case ..<0.1: return "Low"
        case ..<0.2: return "Mid"
        case ..<0.35: return "High"
        default: return "Highest"
        }
    }

    // MARK: Row builders

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption.weight(.bold))
            .foregroundStyle(.white.opacity(0.5))
            .tracking(0.6)
    }

    private func adjustRow(
        _ label: String,
        value: String,
        onDecrement: @escaping () -> Void,
        onIncrement: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.white)
            Spacer(minLength: 8)
            Button(action: onDecrement) {
                Image(systemName: "minus")
                    .font(.body.weight(.bold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.card)
            Text(value)
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(minWidth: 62)
            Button(action: onIncrement) {
                Image(systemName: "plus")
                    .font(.body.weight(.bold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.card)
        }
        .padding(.vertical, 2)
    }

    private func cycleRow(
        _ label: String,
        value: String,
        swatch: SubtitleColor?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(label)
                    .font(.callout)
                    .foregroundStyle(.white)
                Spacer(minLength: 8)
                if let swatch {
                    Circle()
                        .fill(swatch.swiftUIColor)
                        .frame(width: 20, height: 20)
                        .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1))
                }
                Text(value)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggleRow(_ label: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.white)
        }
        .padding(.vertical, 2)
    }
}
#endif
