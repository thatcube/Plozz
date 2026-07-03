#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// The values collected when adding a local media share. Passed back to
/// `AppState.didConfigureShare` which mints the account.
struct ShareDraft: Equatable {
    var host: String
    var port: Int?
    var share: String
    var username: String
    var password: String
    var displayName: String
}

/// A small form for adding an SMB media share: address, share name, optional
/// credentials + display name. Deliberately plain — a media share is a
/// second-class backend, so this isn't the polished Plex/Jellyfin sign-in, just
/// enough to point Plozz at a folder of files.
///
/// Matches the other onboarding screens: a shared `OnboardingHeader`, the form
/// inside a bordered `PlozzScrollCard` container (like the Settings sections),
/// and its two actions side-by-side. The first argument to each field doubles
/// as the full-screen keyboard title, so it must read as the field's name.
struct AddShareView: View {
    let onBack: () -> Void
    let onConfigured: (ShareDraft) -> Void

    @State private var host = ""
    @State private var portText = ""
    @State private var share = ""
    @State private var username = ""
    @State private var password = ""
    @State private var displayName = ""

    @FocusState private var focusedField: Field?
    private enum Field { case host, port, share, username, password, name }

    private var canSubmit: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty
            && !share.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 28) {
            OnboardingHeader(
                "Add a Media Share",
                subtitle: "Point Plozz at an SMB folder of movies and TV. Leave the username and password blank for a guest share."
            )

            PlozzScrollCard {
                Form {
                    TextField("Address", text: $host)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .focused($focusedField, equals: .host)
                        .onSubmit { focusedField = .port }

                    TextField("Port (optional, default 445)", text: $portText)
                        .submitLabel(.next)
                        .focused($focusedField, equals: .port)
                        .onSubmit { focusedField = .share }

                    TextField("Share name (e.g. Media)", text: $share)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .focused($focusedField, equals: .share)
                        .onSubmit { focusedField = .username }

                    TextField("Username (optional)", text: $username)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .focused($focusedField, equals: .username)
                        .onSubmit { focusedField = .password }

                    SecureField("Password (optional)", text: $password)
                        .textContentType(.password)
                        .submitLabel(.next)
                        .focused($focusedField, equals: .password)
                        .onSubmit { focusedField = .name }

                    TextField("Display name (optional)", text: $displayName)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .focused($focusedField, equals: .name)
                        .onSubmit { submit() }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
            .frame(maxWidth: 720, maxHeight: 560)

            HStack(spacing: 24) {
                Button(role: .cancel, action: onBack) {
                    Text("Back").frame(minWidth: 220)
                }
                Button(action: submit) {
                    Text("Add Share").frame(minWidth: 220)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSubmit)
            }
        }
        .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
        .padding(.vertical, 48)
        .frame(maxWidth: 900)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onExitCommand(perform: onBack)
        .onAppear { focusedField = .host }
    }

    private func submit() {
        guard canSubmit else { return }
        onConfigured(
            ShareDraft(
                host: host.trimmingCharacters(in: .whitespaces),
                port: Int(portText.trimmingCharacters(in: .whitespaces)),
                share: share.trimmingCharacters(in: .whitespaces),
                username: username.trimmingCharacters(in: .whitespaces),
                password: password,
                displayName: displayName.trimmingCharacters(in: .whitespaces)
            )
        )
    }
}

#endif
