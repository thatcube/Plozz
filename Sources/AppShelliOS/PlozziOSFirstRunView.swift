#if os(iOS)
import CoreModels
import CoreUI
import Foundation
import SwiftUI

struct PlozziOSFirstRunView: View {
    let step: PlozziOSAppModel.FirstRunStep
    let appModel: PlozziOSAppModel
    let systemColorScheme: ColorScheme

    var body: some View {
        NavigationStack {
            switch step {
            case .profiles:
                PlozziOSProfilesWelcomeView(appModel: appModel)
            case .confirmProfile:
                PlozziOSFirstProfileView(appModel: appModel)
            case .theme:
                PlozziOSThemeWelcomeView(appModel: appModel)
            }
        }
        .scrollContentBackground(.hidden)
        .background { AppBackground(palette: palette) }
        .environment(\.themePalette, palette)
        .environment(\.colorScheme, palette.isLight ? .light : .dark)
        .preferredColorScheme(palette.isLight ? .light : .dark)
        .toolbarBackground(.hidden, for: .navigationBar)
        .interactiveDismissDisabled()
    }

    private var palette: ThemePalette {
        ThemePalette.palette(
            for: appModel.settings.theme.theme,
            systemColorScheme: systemColorScheme
        )
    }
}

private struct PlozziOSProfilesWelcomeView: View {
    let appModel: PlozziOSAppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 54, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 112, height: 112)
                    .background(Color.accentColor.opacity(0.14), in: Circle())

                VStack(spacing: 10) {
                    Text("Who’s watching?")
                        .font(.largeTitle.bold())
                    Text("Profiles keep each person’s Home, watch history, settings, and downloads separate.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 12) {
                    PlozziOSFirstRunHighlight(
                        systemImage: "house.fill",
                        text: "Personal Home rows and library visibility"
                    )
                    PlozziOSFirstRunHighlight(
                        systemImage: "externaldrive.fill",
                        text: "Choose which media sources each profile uses"
                    )
                    PlozziOSFirstRunHighlight(
                        systemImage: "arrow.down.circle.fill",
                        text: "Separate offline downloads for every profile"
                    )
                }

                VStack(spacing: 12) {
                    Button("Use Profiles") {
                        appModel.enableProfilesForFirstRun()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)

                    Button("Not Now — Just Me") {
                        appModel.declineProfilesForFirstRun()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                }

                Text("You can enable profiles later in Settings.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 640)
            .padding(.horizontal, 24)
            .padding(.vertical, 44)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Welcome to Plozz")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PlozziOSFirstProfileView: View {
    let appModel: PlozziOSAppModel
    @State private var editing = false

    private var profile: Profile { appModel.profiles.activeProfile }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                PlozziOSProfileAvatar(profile: profile, size: 128)

                VStack(spacing: 8) {
                    Text(profile.name)
                        .font(.largeTitle.bold())
                    Text("We created this profile from your first media account.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 12) {
                    Button("Looks Good") {
                        appModel.confirmFirstRunProfile()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)

                    Button("Edit Profile", systemImage: "pencil") {
                        editing = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: 520)
            .padding(.horizontal, 24)
            .padding(.vertical, 56)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Your Profile")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $editing) {
            NavigationStack {
                PlozziOSProfileEditorView(
                    profile: profile,
                    onSave: { name, emoji in
                        appModel.updateProfile(profile.id, name: name, emoji: emoji)
                        editing = false
                    },
                    onCancel: { editing = false }
                )
            }
        }
    }
}

private struct PlozziOSThemeWelcomeView: View {
    let appModel: PlozziOSAppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 10) {
                    Text("Choose Your Look")
                        .font(.largeTitle.bold())
                    Text("Pick a theme for this profile. You can change it any time.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 150), spacing: 14)],
                    spacing: 14
                ) {
                    ForEach(AppTheme.pickerOrder) { theme in
                        Button {
                            appModel.settings.theme.theme = theme
                        } label: {
                            VStack(spacing: 14) {
                                Image(systemName: theme.symbolName)
                                    .font(.system(size: 32, weight: .semibold))
                                Text(theme.displayName)
                                    .font(.headline)
                            }
                            .frame(maxWidth: .infinity, minHeight: 120)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
                            .overlay {
                                RoundedRectangle(cornerRadius: 18)
                                    .stroke(
                                        appModel.settings.theme.theme == theme
                                            ? Color.accentColor
                                            : Color.secondary.opacity(0.2),
                                        lineWidth: appModel.settings.theme.theme == theme ? 3 : 1
                                    )
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(
                            appModel.settings.theme.theme == theme ? .isSelected : []
                        )
                    }
                }

                Button("Continue") {
                    appModel.finishFirstRunThemeSelection()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: 720)
            .padding(.horizontal, 24)
            .padding(.vertical, 48)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct PlozziOSProfileEditorView: View {
    let profile: Profile
    let onSave: (String, String?) -> Void
    let onCancel: () -> Void

    @State private var name: String
    @State private var emoji: String

    init(
        profile: Profile,
        onSave: @escaping (String, String?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.profile = profile
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: profile.name)
        _emoji = State(initialValue: profile.avatarEmoji ?? "👤")
    }

    var body: some View {
        Form {
            Section("Profile") {
                TextField("Name", text: $name)
                    .textContentType(.name)
                TextField("Emoji", text: $emoji)
            }
        }
        .settingsPageSurface()
        .navigationTitle("Edit Profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: onCancel)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    onSave(name, emoji)
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}

struct PlozziOSProfileAvatar: View {
    let profile: Profile
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.accentColor.opacity(0.15))

            if let source = profile.avatarImageURL,
               let url = URL(string: source) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    fallback
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    @ViewBuilder
    private var fallback: some View {
        if let emoji = profile.avatarEmoji, !emoji.isEmpty {
            Text(emoji)
                .font(.system(size: size * 0.46))
        } else {
            Image(systemName: profile.avatarSymbol)
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(.tint)
        }
    }
}

private struct PlozziOSFirstRunHighlight: View {
    let systemImage: String
    let text: LocalizedStringKey

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 30)
            Text(text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
#endif
