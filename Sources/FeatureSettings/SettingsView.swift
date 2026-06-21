#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// Settings: account info, full caption customization, and sign out.
///
/// Uses only tvOS-supported controls — `Toggle`, `Picker`, `Button` — since
/// `Slider` isn't available on tvOS. Caption changes apply immediately and
/// persist via `CaptionSettingsModel`.
public struct SettingsView: View {
    @State private var captions: CaptionSettingsModel
    private let userName: String
    private let serverName: String
    private let serverURL: String
    private let appVersion: String
    private let onSignOut: () -> Void

    public init(
        captions: CaptionSettingsModel,
        userName: String,
        serverName: String,
        serverURL: String,
        appVersion: String,
        onSignOut: @escaping () -> Void
    ) {
        _captions = State(initialValue: captions)
        self.userName = userName
        self.serverName = serverName
        self.serverURL = serverURL
        self.appVersion = appVersion
        self.onSignOut = onSignOut
    }

    private let fontScales: [Double] = [0.75, 1.0, 1.25, 1.5, 2.0]
    private let backgroundOpacities: [Double] = [0.0, 0.25, 0.5, 0.75, 1.0]

    public var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    LabeledContent("Signed in as", value: userName)
                    LabeledContent("Server", value: serverName)
                    LabeledContent("Address", value: serverURL)
                }

                Section("Captions") {
                    Toggle("Use system caption style", isOn: $captions.settings.followsSystemStyle)

                    if !captions.settings.followsSystemStyle {
                        Picker("Text size", selection: $captions.settings.fontScale) {
                            ForEach(fontScales, id: \.self) { scale in
                                Text("\(Int(scale * 100))%").tag(scale)
                            }
                        }

                        Picker("Text color", selection: $captions.settings.textColor) {
                            ForEach(CaptionSettings.RGBAColor.presets, id: \.name) { preset in
                                Text(preset.name).tag(preset.color)
                            }
                        }

                        Picker("Background", selection: $captions.settings.backgroundColor.alpha) {
                            ForEach(backgroundOpacities, id: \.self) { opacity in
                                Text(opacity == 0 ? "Off" : "\(Int(opacity * 100))%").tag(opacity)
                            }
                        }

                        Picker("Edge style", selection: $captions.settings.edgeStyle) {
                            ForEach(CaptionSettings.EdgeStyle.allCases, id: \.self) { style in
                                Text(style.displayName).tag(style)
                            }
                        }

                        CaptionPreview(settings: captions.settings)
                    }
                }

                Section {
                    Button(role: .destructive, action: onSignOut) {
                        Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                } footer: {
                    Text("Plizz \(appVersion) · Open source")
                }
            }
            .navigationTitle("Settings")
        }
    }
}

/// Live preview of how captions will look with the current settings.
private struct CaptionPreview: View {
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
        .clipShape(RoundedRectangle(cornerRadius: PlizzTheme.Metrics.cornerRadius))
        .padding(.vertical, 8)
    }
}

extension CaptionSettings.RGBAColor {
    var swiftUIColor: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}

#endif
