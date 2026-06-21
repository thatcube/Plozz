#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// A reusable, self-contained editor for `CaptionSettings`, styled in the
/// Twozz horizontal-card look (choices laid out as focusable tiles rather than
/// stacked pickers) with a live preview.
///
/// It binds directly to a `CaptionSettings` value, so it works equally well in
/// the Settings screen **and** from inside the player view — the spec requires
/// caption/subtitle controls to be reachable while watching, and keeping the UI
/// here (CoreUI, on the shared `CoreModels` type) means the player can drop the
/// same component into an overlay without forking the model or the layout.
public struct CaptionSettingsCard: View {
    @Binding private var settings: CaptionSettings

    /// When `true`, the auto-download / preferred-language controls are hidden.
    /// The player only needs the *appearance* controls (and the on/off + style),
    /// not server-side subtitle fetching, so it can opt out of them.
    private let showsDownloadControls: Bool

    public init(settings: Binding<CaptionSettings>, showsDownloadControls: Bool = true) {
        self._settings = settings
        self.showsDownloadControls = showsDownloadControls
    }

    private let fontScales: [Double] = [0.75, 1.0, 1.25, 1.5, 2.0]
    private let backgroundOpacities: [Double] = [0.0, 0.25, 0.5, 0.75, 1.0]

    /// A short, common-language list for the subtitle language picker. Codes are
    /// 2-letter ISO-639-1; the provider normalises to the server's expected form.
    public static let subtitleLanguages: [(code: String, name: String)] = [
        ("en", "English"), ("es", "Spanish"), ("fr", "French"), ("de", "German"),
        ("it", "Italian"), ("pt", "Portuguese"), ("nl", "Dutch"), ("sv", "Swedish"),
        ("no", "Norwegian"), ("da", "Danish"), ("fi", "Finnish"), ("pl", "Polish"),
        ("ru", "Russian"), ("ja", "Japanese"), ("ko", "Korean"), ("zh", "Chinese"),
        ("ar", "Arabic"), ("tr", "Turkish")
    ]

    public var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            if showsDownloadControls {
                subtitleBehaviorGroup
            }
            styleGroup
        }
    }

    // MARK: Subtitle behaviour

    @ViewBuilder
    private var subtitleBehaviorGroup: some View {
        SettingsSubGroup("Subtitles") {
            Toggle("Automatically download subtitles", isOn: $settings.autoDownloadSubtitles)
                .padding(.trailing, 4)

            labeledRow("Show subtitles") {
                OptionCardRow(
                    options: CaptionSettings.SubtitleMode.allCases,
                    selection: $settings.subtitleMode
                ) { mode in
                    optionLabel(mode.displayName)
                }
            }

            labeledRow("Subtitle language") {
                OptionCardRow(options: languageOptions, selection: languageSelection) { code in
                    optionLabel(languageName(for: code))
                }
            }
        }
    }

    // MARK: Appearance

    @ViewBuilder
    private var styleGroup: some View {
        SettingsSubGroup("Caption Style") {
            Toggle("Use system caption style", isOn: $settings.followsSystemStyle)
                .padding(.trailing, 4)

            if !settings.followsSystemStyle {
                labeledRow("Text size") {
                    OptionCardRow(options: fontScales, selection: $settings.fontScale) { scale in
                        optionLabel("\(Int(scale * 100))%")
                    }
                }

                labeledRow("Text color") {
                    OptionCardRow(options: textColorOptions, selection: $settings.textColor) { color in
                        colorLabel(color)
                    }
                }

                labeledRow("Background") {
                    OptionCardRow(options: backgroundOpacities, selection: $settings.backgroundColor.alpha) { opacity in
                        optionLabel(opacity == 0 ? "Off" : "\(Int(opacity * 100))%")
                    }
                }

                labeledRow("Edge style") {
                    OptionCardRow(
                        options: CaptionSettings.EdgeStyle.allCases,
                        selection: $settings.edgeStyle
                    ) { style in
                        optionLabel(style.displayName)
                    }
                }

                CaptionPreview(settings: settings)
            }
        }
    }

    // MARK: Option data

    private var languageOptions: [String] {
        [""] + Self.subtitleLanguages.map(\.code)
    }

    /// Bridges the optional `preferredSubtitleLanguage` to a non-optional
    /// selection (empty string == "Device Default") so it fits `OptionCardRow`.
    private var languageSelection: Binding<String> {
        Binding(
            get: { settings.preferredSubtitleLanguage ?? "" },
            set: { settings.preferredSubtitleLanguage = $0.isEmpty ? nil : $0 }
        )
    }

    private func languageName(for code: String) -> String {
        guard !code.isEmpty else { return "Device Default" }
        return Self.subtitleLanguages.first(where: { $0.code == code })?.name ?? code
    }

    private var textColorOptions: [CaptionSettings.RGBAColor] {
        CaptionSettings.RGBAColor.presets.map(\.color)
    }

    // MARK: Label helpers

    private func optionLabel(_ text: String) -> some View {
        Text(text)
            .font(.headline)
            .multilineTextAlignment(.center)
    }

    private func colorLabel(_ color: CaptionSettings.RGBAColor) -> some View {
        let name = CaptionSettings.RGBAColor.presets.first(where: { $0.color == color })?.name ?? "Custom"
        return VStack(spacing: 10) {
            Circle()
                .fill(color.swiftUIColor)
                .frame(width: 36, height: 36)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.4), lineWidth: 1))
            Text(name).font(.headline)
        }
    }

    @ViewBuilder
    private func labeledRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            content()
        }
    }
}

/// A titled grouping inside a caption card — a small header above its controls,
/// used to keep "Subtitles" and "Caption Style" visually distinct.
private struct SettingsSubGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.title3.weight(.semibold))
            content
        }
    }
}

/// Live preview of how captions will look with the current settings.
struct CaptionPreview: View {
    let settings: CaptionSettings

    var body: some View {
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

public extension CaptionSettings.RGBAColor {
    var swiftUIColor: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}

#endif
