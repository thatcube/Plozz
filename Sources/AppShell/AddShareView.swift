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
struct AddShareView: View {
    let onBack: () -> Void
    let onConfigured: (ShareDraft) -> Void

    @State private var host = ""
    @State private var portText = ""
    @State private var share = ""
    @State private var username = ""
    @State private var password = ""
    @State private var displayName = ""

    private var canSubmit: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty
            && !share.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 16) {
                ProviderBrandMark(provider: .mediaShare, size: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Local Media Share")
                        .font(.title2).bold()
                    Text("Point Plozz at an SMB folder of movies and TV. Leave the account blank for a guest/public share.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 700, alignment: .leading)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 16) {
                field("Address", text: $host, prompt: "192.168.1.10 or nas.local")
                field("Port", text: $portText, prompt: "445 (optional)")
                field("Share", text: $share, prompt: "Media")
                field("Username", text: $username, prompt: "Optional")
                secureField("Password", text: $password)
                field("Name", text: $displayName, prompt: "Optional — shown in the app")
            }
            .frame(maxWidth: 900)

            HStack(spacing: 16) {
                Button("Back", action: onBack)
                    .buttonStyle(.bordered)
                Button("Add Share") {
                    onConfigured(makeDraft())
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSubmit)
            }
            .padding(.top, 8)
        }
        .padding(60)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onExitCommand(perform: onBack)
    }

    private func makeDraft() -> ShareDraft {
        ShareDraft(
            host: host.trimmingCharacters(in: .whitespaces),
            port: Int(portText.trimmingCharacters(in: .whitespaces)),
            share: share.trimmingCharacters(in: .whitespaces),
            username: username.trimmingCharacters(in: .whitespaces),
            password: password,
            displayName: displayName
        )
    }

    private func field(_ label: String, text: Binding<String>, prompt: String) -> some View {
        GridRow {
            Text(label).font(.headline).gridColumnAlignment(.trailing)
            TextField(prompt, text: text)
                .textContentType(.URL)
                .autocorrectionDisabled()
                .frame(minWidth: 520)
        }
    }

    private func secureField(_ label: String, text: Binding<String>) -> some View {
        GridRow {
            Text(label).font(.headline).gridColumnAlignment(.trailing)
            SecureField("Optional", text: text)
                .frame(minWidth: 520)
        }
    }
}

#endif
