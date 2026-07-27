#if os(iOS)
import CoreModels
import CoreUI
import FeatureProfiles
import Foundation
import SwiftUI

struct PlozziOSFirstRunView: View {
    let step: PlozziOSAppModel.FirstRunStep
    let appModel: PlozziOSAppModel
    let systemColorScheme: ColorScheme

    var body: some View {
        NavigationStack {
            switch step {
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

private struct PlozziOSFirstProfileView: View {
    let appModel: PlozziOSAppModel
    @State private var editing = false

    private var profile: Profile { appModel.profiles.activeProfile }

    var body: some View {
        // Centre the column when the screen is taller than the content (every
        // iPad, and iPhone portrait) instead of stranding it at the top with a
        // screenful of dead space below. `minHeight` keeps it scrollable when
        // the content IS taller, e.g. iPhone landscape or large Dynamic Type.
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 32) {
                    editableAvatar

                    VStack(spacing: 8) {
                        Text(profile.name)
                            .font(.largeTitle.bold())
                        Text("We created this profile from your first media account. Tap the photo to rename it or pick a different picture.")
                            .plozzForeground(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    Button("Looks Good") {
                        appModel.confirmFirstRunProfile()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)

                    Text("Add a profile for anyone else in Settings. Each one keeps its own settings, Home, watch history, and downloads — your servers stay shared.")
                        .font(.footnote)
                        .plozzForeground(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: 520)
                .padding(.horizontal, 24)
                .padding(.vertical, 40)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
        }
        .sheet(isPresented: $editing) {
            NavigationStack {
                PlozziOSProfileEditorHost(
                    appModel: appModel,
                    editingProfile: profile,
                    canDelete: false,
                    onFinished: { editing = false }
                )
            }
        }
    }

    /// The avatar IS the edit control, labelled with the word "Edit" on a neutral
    /// capsule straddling its lower edge. Neutral rather than accent-coloured so
    /// it stays subordinate to "Looks Good" — that button is the screen's only
    /// call to action, and a second blue control would compete with it.
    private var editableAvatar: some View {
        Button {
            editing = true
        } label: {
            PlozziOSProfileAvatar(profile: profile, size: 128)
                .overlay(alignment: .bottom) {
                    Text("Edit")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                        .overlay(
                            Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                        )
                        .offset(y: 12)
                }
                // Room for the capsule to hang past the avatar without the name
                // below closing the gap on it.
                .padding(.bottom, 12)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Edit profile")
        .accessibilityHint("Rename this profile or change its picture")
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
                        .plozzForeground(.secondary)
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

struct PlozziOSProfileAvatar: View {
    let profile: Profile
    let size: CGFloat

    var body: some View {
        // Delegate to the shared renderer so the first-run / settings avatars
        // match every other avatar surface (photo, emoji, or symbol on the
        // chosen colour) exactly.
        ProfileAvatarView(profile: profile, size: size)
    }
}

#endif
