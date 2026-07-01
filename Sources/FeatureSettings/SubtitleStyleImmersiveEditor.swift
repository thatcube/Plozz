#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// **UX prototype** for the immersive subtitle-style editor.
///
/// This is the shape both Settings and the player will share: a fixed live
/// preview with a floating control column over it. In Settings the preview is a
/// synthetic *tri-band* legibility card (solid white · rainbow · solid black) so
/// you can judge readability against the worst backdrops at once; in the player
/// the same control column will float over the real video instead.
///
/// The layout is deliberately **invariant** — always `preview | controls`. What
/// the host `SettingsSplitLayout` calls "expanding" is purely the pane growing
/// (index collapses, card chrome drops) to give this same editor more room. No
/// focusable control is inserted or removed on the transition, so focus can
/// never be yanked back out to the master list.
///
/// Bound to a local `SubtitleStyle` for now (the single source of truth
/// migration comes next); the controls are a representative subset so the
/// choreography and preview can be felt on-device before the full knob set and
/// persistence are wired.
struct SubtitleStyleImmersiveEditor: View {
    @Environment(\.settingsDetailExpanded) private var expanded

    @State private var style = SubtitleStyle.default
    @State private var presetID: String = SubtitleStyle.presets.first?.id ?? "clean"

    private let fontScales: [Double] = [0.75, 1.0, 1.25, 1.5, 2.0]
    private let positions: [Double] = [0.06, 0.14, 0.24, 0.36, 0.48]

    var body: some View {
        HStack(spacing: 0) {
            SubtitlePreviewCard(style: style)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            controlColumn
                .frame(width: 440)
        }
    }

    // MARK: Controls

    private var controlColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Subtitle Style")
                .font(.title2.weight(.bold))
            Text(expanded
                 ? "Tweak the look — the preview updates live."
                 : "Press → to customize.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.bottom, 18)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    group("Preset") {
                        SettingsSegmentedPicker(
                            options: SubtitleStyle.presets.map(\.id),
                            selection: presetBinding,
                            title: presetName
                        )
                    }

                    LabeledSettingRow("Text size", labelWidth: 150) {
                        SettingsStepper(options: fontScales, selection: $style.fontScale) {
                            "\(Int($0 * 100))%"
                        }
                    }

                    LabeledSettingRow("Position", labelWidth: 150) {
                        SettingsStepper(options: positions, selection: $style.verticalPosition,
                                        title: positionName)
                    }

                    group("Text color") {
                        SettingsSegmentedPicker(
                            options: colorOptions,
                            selection: $style.textColor,
                            title: colorName
                        )
                    }

                    LabeledSettingRow("Background", labelWidth: 150) {
                        Toggle("", isOn: $style.background.isEnabled).labelsHidden()
                    }

                    LabeledSettingRow("Outline", labelWidth: 150) {
                        Toggle("", isOn: $style.border.isEnabled).labelsHidden()
                    }
                }
                .padding(.bottom, 40)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.black.opacity(0.55))
    }

    @ViewBuilder
    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .textCase(.uppercase)
                .tracking(1.0)
                .foregroundStyle(.secondary)
            content()
        }
    }

    // MARK: Bindings & option data

    private var presetBinding: Binding<String> {
        Binding(
            get: { presetID },
            set: { id in
                presetID = id
                if let preset = SubtitleStyle.presets.first(where: { $0.id == id }) {
                    style = preset.style
                }
            }
        )
    }

    private var colorOptions: [SubtitleStyle.Color] {
        CaptionSettings.RGBAColor.presets.map(\.color)
    }

    private func presetName(_ id: String) -> String {
        SubtitleStyle.presets.first(where: { $0.id == id })?.name ?? id.capitalized
    }

    private func colorName(_ color: SubtitleStyle.Color) -> String {
        CaptionSettings.RGBAColor.presets.first(where: { $0.color == color })?.name ?? "Custom"
    }

    private func positionName(_ value: Double) -> String {
        switch value {
        case ..<0.10: return "Bottom"
        case ..<0.20: return "Low"
        case ..<0.30: return "Middle"
        case ..<0.42: return "High"
        default: return "Top"
        }
    }
}

/// The fixed tri-band legibility preview: three vertical zones (white · rainbow ·
/// black) with a representative subtitle line rendered from `style`, positioned
/// by its vertical/horizontal placement so those controls read truthfully.
struct SubtitlePreviewCard: View {
    let style: SubtitleStyle

    /// Eight unit directions used to fake a glyph outline cheaply.
    private static let outlineOffsets: [CGSize] = [
        .init(width: -1, height: 0), .init(width: 1, height: 0),
        .init(width: 0, height: -1), .init(width: 0, height: 1),
        .init(width: -1, height: -1), .init(width: 1, height: -1),
        .init(width: -1, height: 1), .init(width: 1, height: 1)
    ]

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                HStack(spacing: 0) {
                    Color.white
                    LinearGradient(
                        colors: [.red, .orange, .yellow, .green, .blue, .purple],
                        startPoint: .leading, endPoint: .trailing
                    )
                    Color.black
                }

                subtitle(maxWidth: geo.size.width * 0.9)
                    .offset(
                        x: CGFloat(style.horizontalOffset) * geo.size.width * 0.28,
                        y: -CGFloat(style.verticalPosition) * (geo.size.height - 140)
                    )
                    .padding(.bottom, 28)
            }
        }
    }

    @ViewBuilder
    private func subtitle(maxWidth: CGFloat) -> some View {
        let size = 42 * style.fontScale
        let base = Text("The quick brown fox")
            .font(.system(size: size, weight: .semibold))

        ZStack {
            if style.border.isEnabled {
                ForEach(Array(Self.outlineOffsets.enumerated()), id: \.offset) { _, off in
                    base
                        .foregroundStyle(style.border.color.swiftUIColor)
                        .offset(x: off.width * style.border.width,
                                y: off.height * style.border.width)
                }
            }
            base.foregroundStyle(style.textColor.swiftUIColor)
        }
        .padding(.horizontal, style.background.horizontalPadding)
        .padding(.vertical, style.background.verticalPadding)
        .background(
            Group {
                if style.background.isEnabled {
                    RoundedRectangle(cornerRadius: style.background.cornerRadius, style: .continuous)
                        .fill(style.background.color.swiftUIColor)
                }
            }
        )
        .shadow(
            color: style.edge.style == .dropShadow ? style.edge.color.swiftUIColor : .clear,
            radius: style.edge.style == .dropShadow ? style.edge.thickness * 1.6 : 0,
            y: style.edge.style == .dropShadow ? style.edge.thickness : 0
        )
        .opacity(style.opacity)
        .frame(maxWidth: maxWidth)
        .multilineTextAlignment(.center)
    }
}
#endif
