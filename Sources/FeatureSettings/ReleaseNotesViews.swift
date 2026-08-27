#if canImport(SwiftUI)
import CoreModels
import CoreUI
import SwiftUI

public struct ReleaseNotesSettingsView: View {
    private let model: ReleaseNotesModel

    public init(model: ReleaseNotesModel) {
        self.model = model
    }

    public var body: some View {
        #if os(tvOS)
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                SettingsPageHeader("Release Notes")
                ReleaseNotesStartupPreferenceView(model: model)
                ForEach(model.allVersionGroups) { group in
                    ReleaseNotesVersionCard(group: group)
                }
            }
            .frame(maxWidth: 1200, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
            .padding(.vertical, 40)
        }
        .scrollClipDisabled()
        #else
        List {
            ReleaseNotesStartupPreferenceView(model: model)

            ForEach(model.allVersionGroups) { group in
                SettingsSectionGroup(verbatim: group.version) {
                    ReleaseNotesSectionsView(sections: group.sections)
                }
            }
        }
        .settingsPageSurface()
        .navigationTitle("Release Notes")
        #endif
    }
}

public struct ReleaseNotesStartupView: View {
    private enum FocusedAction: Hashable {
        case done
        case disable
    }

    private let model: ReleaseNotesModel
    @State private var confirmsDisable = false
    @FocusState private var focusedAction: FocusedAction?

    public init(model: ReleaseNotesModel) {
        self.model = model
    }

    public var body: some View {
        #if os(tvOS)
        ZStack {
            Color.black.opacity(0.72)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 28) {
                Text("What’s New in Plozz")
                    .font(.title.bold())

                FadingScrollView(maxHeight: 560) {
                    ReleaseNotesVersionList(groups: model.pendingVersionGroups)
                        .padding(.horizontal, 8)
                }

                HStack(spacing: 24) {
                    Button("Done") {
                        model.dismissStartupNotes()
                    }
                    .buttonStyle(.borderedProminent)
                    .focused($focusedAction, equals: .done)

                    Button("Don’t Show Again", role: .destructive) {
                        confirmsDisable = true
                    }
                    .buttonStyle(.bordered)
                    .focused($focusedAction, equals: .disable)
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(48)
            .frame(maxWidth: 1280)
            .background(.ultraThinMaterial)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: PlozzTheme.Metrics.mediumCardCornerRadius,
                    style: .continuous
                )
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: PlozzTheme.Metrics.mediumCardCornerRadius,
                    style: .continuous
                )
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.45), radius: 42, y: 18)
            .padding(80)
        }
        .onAppear { focusedAction = .done }
        .onExitCommand { model.dismissStartupNotes() }
        .alert("Don’t show release notes again?", isPresented: $confirmsDisable) {
            Button("Don’t Show Again", role: .destructive) {
                model.setShowsOnStartup(false)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can still view every release in Settings.")
        }
        #else
        NavigationStack {
            ScrollView {
                VStack(spacing: 32) {
                    ReleaseNotesVersionList(groups: model.pendingVersionGroups)

                    Button("Don’t Show Again", role: .destructive) {
                        confirmsDisable = true
                    }
                    .buttonStyle(.bordered)
                    .padding(.bottom, 24)
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
            }
            .navigationTitle("What’s New in Plozz")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        model.dismissStartupNotes()
                    }
                }
            }
        }
        .alert("Don’t show release notes again?", isPresented: $confirmsDisable) {
            Button("Don’t Show Again", role: .destructive) {
                model.setShowsOnStartup(false)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can still view every release in Settings.")
        }
        #endif
    }
}

private struct ReleaseNotesStartupPreferenceView: View {
    let model: ReleaseNotesModel

    var body: some View {
        #if os(tvOS)
        SettingsPanel(title: "Startup") {
            ReleaseNotesPreferenceToggle(model: model)
                .toggleStyle(SettingsSwitchToggleStyle())
        }
        #else
        SettingsSectionGroup("Startup") {
            ReleaseNotesPreferenceToggle(model: model)
        }
        #endif
    }
}

private struct ReleaseNotesPreferenceToggle: View {
    let model: ReleaseNotesModel

    var body: some View {
        Toggle(
            "Show release notes on startup for new versions",
            isOn: Binding(
                get: { model.showsOnStartup },
                set: { model.setShowsOnStartup($0) }
            )
        )
    }
}

private struct ReleaseNotesVersionList: View {
    let groups: [ReleaseNotesVersionGroup]

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 28) {
            ForEach(groups) { group in
                ReleaseNotesVersionCard(group: group)
            }
        }
    }
}

private struct ReleaseNotesVersionCard: View {
    let group: ReleaseNotesVersionGroup

    var body: some View {
        ReleaseNotesVersionContent(group: group)
            .plozzSurface(
                .raised,
                cornerRadius: PlozzTheme.Metrics.mediumCardCornerRadius
            )
    }
}

private struct ReleaseNotesVersionContent: View {
    let group: ReleaseNotesVersionGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(verbatim: group.version)
                .font(.title2.bold())
            ReleaseNotesSectionsView(sections: group.sections)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(28)
    }
}

private struct ReleaseNotesSectionsView: View {
    let sections: [ReleaseNotesSection]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: 10) {
                    Text(verbatim: section.category.rawValue)
                        .font(.headline)

                    ForEach(section.items, id: \.self) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(verbatim: "•")
                            Text(verbatim: item)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .plozzForeground(.secondary)
                        #if os(tvOS)
                        // tvOS scrolls by moving focus. One stop per note lets a
                        // release taller than the dialog scroll continuously
                        // without turning the whole card into one trapped stop.
                        .focusable()
                        .focusEffectDisabled()
                        #endif
                    }
                }
            }
        }
    }
}
#endif
