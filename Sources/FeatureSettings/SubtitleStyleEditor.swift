#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// The full subtitle-style editor rendered as a *single* detail panel: a master
/// "use system style" toggle on top, and — when that's off — the size / colour /
/// background / edge controls plus one live preview beneath it.
///
/// This folds what used to be a separate "Subtitle Style" sub-page (a split
/// view with one master row per attribute) into one right-hand pane, so the
/// Playback page no longer drills into another navigation level just to tweak
/// how subtitles look. Bind it to the profile's `CaptionSettings`.
struct SubtitleStyleEditor: View {
    @Binding var settings: CaptionSettings

    private let fontScales: [Double] = [0.75, 1.0, 1.25, 1.5, 2.0]
    private let backgroundOpacities: [Double] = [0.0, 0.25, 0.5, 0.75, 1.0]

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            Toggle("Use system style", isOn: $settings.followsSystemStyle)

            if !settings.followsSystemStyle {
                VStack(alignment: .leading, spacing: 24) {
                    LabeledSettingRow("Text size") {
                        SettingsStepper(
                            options: fontScales,
                            selection: $settings.fontScale,
                            title: { "\(Int($0 * 100))%" }
                        )
                    }

                    LabeledSettingRow("Background") {
                        SettingsStepper(
                            options: backgroundOpacities,
                            selection: $settings.backgroundColor.alpha,
                            title: { $0 == 0 ? "Off" : "\(Int($0 * 100))%" }
                        )
                    }

                    LabeledSettingRow("Edge style") {
                        SettingsStepper(
                            options: CaptionSettings.EdgeStyle.allCases,
                            selection: $settings.edgeStyle,
                            title: { $0.displayName }
                        )
                    }

                    labeledControl("Text color") {
                        OptionCardRow(options: textColorOptions, selection: $settings.textColor) {
                            colorLabel($0)
                        }
                    }

                    preview
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.22), value: settings.followsSystemStyle)
    }

    // MARK: Option data

    private var textColorOptions: [CaptionSettings.RGBAColor] {
        CaptionSettings.RGBAColor.presets.map(\.color)
    }

    private func colorName(for color: CaptionSettings.RGBAColor) -> String {
        CaptionSettings.RGBAColor.presets.first(where: { $0.color == color })?.name ?? "Custom"
    }

    // MARK: Building blocks

    /// A label above its control, so the horizontal `OptionCardRow` tiles read as
    /// belonging to a named attribute without stealing the section-header look.
    @ViewBuilder
    private func labeledControl<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func colorLabel(_ color: CaptionSettings.RGBAColor) -> some View {
        VStack(spacing: 10) {
            Circle()
                .fill(color.swiftUIColor)
                .frame(width: 36, height: 36)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.4), lineWidth: 1))
            Text(colorName(for: color)).font(.headline)
        }
    }

    /// Live preview of how subtitles will look with the current style.
    private var preview: some View {
        VStack {
            Spacer()
            Text("The quick brown fox")
                .font(.system(size: 32 * settings.fontScale))
                .foregroundStyle(settings.textColor.swiftUIColor)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(settings.backgroundColor.swiftUIColor)
                .shadow(radius: settings.edgeStyle == .dropShadow ? 4 : 0)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
        .background(LinearGradient(colors: [.blue, .purple], startPoint: .top, endPoint: .bottom))
        .clipShape(RoundedRectangle(cornerRadius: PlozzTheme.Metrics.cornerRadius))
        .padding(.top, 8)
    }
}
#endif
