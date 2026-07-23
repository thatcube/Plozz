#if os(iOS)
import CoreModels
import CoreUI
import FeatureSettings
import SwiftUI

/// Native iPhone/iPad Metadata settings, styled like every other `PlozziOS…`
/// settings page (`Form` + `SettingsSectionGroup` + `.settingsPageSurface()`)
/// rather than the tvOS glass-panel `MetadataSettingsDetailView`. Drives the same
/// household-wide models (provider order, cache budgets, TMDB key) through the
/// shared `MetadataProviderListLogic`, so behaviour matches tvOS exactly.
struct PlozziOSMetadataSettingsView: View {
    let deps: MetadataSettingsDependencies

    @State private var showDiagnostics = false

    private var providers: MetadataProviderSettingsModel { deps.providers }
    private var tmdbKey: TMDBUserKeyModel { deps.tmdbKey }

    var body: some View {
        Form {
            Text("Metadata providers, artwork, and caches are shared by every profile on this device.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            providersSection
            if providers.settings.orderMode == .custom {
                prioritySection
            }
            tmdbSection
            diagnosticsSection
        }
        .settingsPageSurface()
        .navigationTitle("Metadata")
        .navigationDestination(isPresented: $showDiagnostics) {
            PlozziOSMetadataDiagnosticsView(deps: deps)
        }
    }

    // MARK: Providers

    private var sections: MetadataProviderListLogic.Sections {
        MetadataProviderListLogic.sections(
            settings: providers.settings,
            baselineOrder: deps.baselineOrder,
            baselineDisabled: deps.baselineDisabled
        )
    }

    private var orderModeBinding: Binding<MetadataProviderOrderMode> {
        Binding(
            get: { providers.settings.orderMode },
            set: { mode in
                providers.settings = MetadataProviderListLogic.settings(
                    providers.settings,
                    selecting: mode,
                    baselineOrder: deps.baselineOrder,
                    baselineDisabled: deps.baselineDisabled
                )
            }
        )
    }

    private var preferLocalArtworkBinding: Binding<Bool> {
        Binding(
            get: { !providers.settings.preferOnlineArtwork },
            set: { providers.settings.preferOnlineArtwork = !$0 }
        )
    }

    @ViewBuilder
    private var providersSection: some View {
        SettingsSectionGroup("Providers") {
            Picker("Order", selection: orderModeBinding) {
                ForEach(MetadataProviderOrderMode.allCases, id: \.self) { mode in
                    Text(orderModeTitle(mode)).tag(mode)
                }
            }
            Toggle("Prefer local artwork", isOn: preferLocalArtworkBinding)
        } footer: {
            Text(providers.settings.orderMode == .recommended
                ? "Plozz picks the best source for each field automatically."
                : "Drag providers to set priority. Anything below the line is turned off.")
        }
    }

    @ViewBuilder
    private var prioritySection: some View {
        let split = sections
        let items = MetadataProviderListLogic.listItems(for: split)
        Section {
            ForEach(items, id: \.self) { item in
                priorityRow(item, split: split)
                    .moveDisabled(item == .divider)
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            }
            .onMove { offsets, destination in
                let next = MetadataProviderListLogic.moving(
                    fromOffsets: offsets,
                    toOffset: destination,
                    in: split
                )
                providers.settings.setLists(enabled: next.enabled, disabled: next.disabled)
            }
        } header: {
            Text("Priority")
        } footer: {
            Text("Drag to reorder. Sources below the Disabled line are turned off.")
        }
        .environment(\.editMode, .constant(.active))
    }

    @ViewBuilder
    private func priorityRow(
        _ item: MetadataProviderListLogic.ListItem,
        split: MetadataProviderListLogic.Sections
    ) -> some View {
        switch item {
        case let .provider(source):
            let isEnabled = split.enabled.contains(source)
            HStack(spacing: 12) {
                if let index = split.enabled.firstIndex(of: source) {
                    Text(index + 1, format: .number)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 20, alignment: .trailing)
                } else {
                    Image(systemName: "slash.circle")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .frame(minWidth: 20)
                }
                Text(displayName(source))
                    .foregroundStyle(isEnabled ? .primary : .secondary)
                Spacer()
            }
        case .divider:
            HStack(spacing: 8) {
                Text("Disabled")
                    .font(.caption.weight(.bold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Rectangle()
                    .fill(.secondary.opacity(0.4))
                    .frame(height: 1)
            }
            .listRowBackground(Color.secondary.opacity(0.12))
        }
    }

    private func orderModeTitle(_ mode: MetadataProviderOrderMode) -> String {
        switch mode {
        case .recommended: "Recommended"
        case .custom: "Custom"
        }
    }

    // MARK: TMDB bring-your-own-key

    private var draftKeyBinding: Binding<String> {
        Binding(get: { tmdbKey.draftKey }, set: { tmdbKey.draftKey = $0 })
    }

    @ViewBuilder
    private var tmdbSection: some View {
        SettingsSectionGroup("Your Own TMDB Key") {
            if tmdbKey.isConfigured {
                Label("A TMDB key is saved on this device.", systemImage: "checkmark.seal")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            SecureField("TMDB v4 API Read Access Token", text: draftKeyBinding)
                .textContentType(.password)
                .disableAutocorrection(true)
                .autocapitalization(.none)

            tmdbStatusRow

            if let storageError = tmdbKey.storageErrorMessage {
                Label(storageError, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.red)
            }

            Button {
                Task { await tmdbKey.saveDraft() }
            } label: {
                Label(tmdbKey.isConfigured ? "Replace Key" : "Save Key", systemImage: "square.and.arrow.down")
            }
            .disabled(!tmdbKey.canSaveDraft)

            Button {
                Task { await tmdbKey.verify() }
            } label: {
                Label("Verify Key", systemImage: "checkmark.shield")
            }
            .disabled((!tmdbKey.canSaveDraft && !tmdbKey.isConfigured) || tmdbKey.verifyState == .verifying)

            if tmdbKey.isConfigured {
                Button(role: .destructive) {
                    Task { await tmdbKey.remove() }
                } label: {
                    Label("Remove Key", systemImage: "trash")
                }
            }
        } footer: {
            Text("Optional. Use your own TMDB read token so lookups run under your account's rate limit.")
        }
    }

    @ViewBuilder
    private var tmdbStatusRow: some View {
        switch tmdbKey.verifyState {
        case .idle:
            EmptyView()
        case .verifying:
            Label("Checking…", systemImage: "hourglass")
                .font(.callout).foregroundStyle(.secondary)
        case .valid:
            Label("Key verified — TMDB authenticated successfully.", systemImage: "checkmark.circle.fill")
                .font(.callout).foregroundStyle(.green)
        case .invalid:
            Label("TMDB rejected this key. Check the token and try again.", systemImage: "xmark.octagon.fill")
                .font(.callout).foregroundStyle(.red)
        case .unreachable:
            Label("Couldn't reach TMDB to check the key. Try again in a moment.", systemImage: "wifi.exclamationmark")
                .font(.callout).foregroundStyle(.orange)
        }
    }

    // MARK: Diagnostics

    @ViewBuilder
    private var diagnosticsSection: some View {
        SettingsSectionGroup {
            Button {
                showDiagnostics = true
            } label: {
                HStack {
                    Label("Diagnostics", systemImage: "chart.bar.xaxis")
                    Spacer()
                    Text("Cache and provider health")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func displayName(_ source: MetadataSource) -> String {
        MetadataSourceAttribution.for(source)?.name ?? source.rawValue.capitalized
    }
}
#endif
