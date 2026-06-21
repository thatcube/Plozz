#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import FeatureProfiles

/// Hosts the profile picker and its create/edit editor as a sheet.
///
/// Used both at launch (when the household has more than one profile) and from
/// Settings → "Switch Profile". Selecting a profile routes through
/// `AppState.switchProfile`; Add/Edit present `ProfileEditorView`.
struct ProfileSelectionView: View {
    @Bindable var appState: AppState
    /// `true` when there is already an active session behind the picker, so the
    /// picker can be cancelled (Settings entry); `false` at first launch.
    let canCancel: Bool

    @State private var editorContext: EditorContext?

    private enum EditorContext: Identifiable {
        case new
        case edit(Profile)
        var id: String {
            switch self {
            case .new: return "new"
            case let .edit(profile): return profile.id
            }
        }
    }

    var body: some View {
        ProfilePickerView(
            profiles: appState.profilesModel.profiles,
            activeProfileID: appState.profilesModel.activeProfileID,
            onSelect: { appState.switchProfile(to: $0.id) },
            onAddProfile: { editorContext = .new },
            onEditProfile: { editorContext = .edit($0) },
            onCancel: canCancel ? { appState.cancelProfileSelection() } : nil
        )
        .sheet(item: $editorContext) { context in
            editor(for: context)
        }
    }

    @ViewBuilder
    private func editor(for context: EditorContext) -> some View {
        switch context {
        case .new:
            ProfileEditorView(
                accounts: appState.accounts,
                selectedAccountIDs: appState.accounts.map(\.id),
                canDelete: false,
                onSave: { draft in
                    appState.saveProfile(draft)
                    editorContext = nil
                },
                onCancel: { editorContext = nil }
            )
        case let .edit(profile):
            ProfileEditorView(
                editingProfile: profile,
                accounts: appState.accounts,
                selectedAccountIDs: appState.activeAccountIDs(forProfile: profile.id),
                canDelete: !appState.profilesModel.isDefault(profile),
                onSave: { draft in
                    appState.saveProfile(draft)
                    editorContext = nil
                },
                onDelete: {
                    appState.removeProfile(id: profile.id)
                    editorContext = nil
                },
                onCancel: { editorContext = nil }
            )
        }
    }
}
#endif
