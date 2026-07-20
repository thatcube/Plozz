#if os(iOS)
import AppRuntime
import CoreUI
import SwiftUI

struct PlozziOSPlexPINView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: PlexHomeUsersModel
    let request: PlexHomeUsersModel.PlexPINRequest
    @State private var pin = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("PIN", text: $pin)
                        .keyboardType(.numberPad)
                        .textContentType(.password)
                } header: {
                    Text("Unlock \(request.homeUserName)")
                } footer: {
                    if let error = model.plexPINError {
                        Text(error)
                            .foregroundStyle(.red)
                    } else {
                        Text("Enter this Plex Home user’s PIN.")
                    }
                }
            }
            .settingsPageSurface()
            .navigationTitle("Plex PIN")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        model.cancelPlexPIN()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Unlock") {
                        model.submitPlexPIN(pin)
                    }
                    .disabled(pin.isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
#endif
