#if os(iOS)
import AppRuntime
import CoreUI
import SwiftUI

struct PlozziOSPlexPINView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: PlexHomeUsersModel
    let request: PlexHomeUsersModel.PlexPINRequest
    var sequenceStep: PINSequenceStep? = nil
    var dismissOnSuccess = true

    @State private var isSubmitting = false

    var body: some View {
        let pendingRequest = model.pendingPlexPINRequest
        PINEntryScaffold(
            title: "Enter your Plex PIN",
            name: Text(verbatim: request.homeUserName),
            errorMessage: model.plexPINError,
            isSubmitting: isSubmitting,
            sequenceStep: sequenceStep,
            onSubmit: { pin in
                isSubmitting = true
                model.submitPlexPIN(pin)
            },
            onCancel: {
                model.cancelPlexPIN()
                if dismissOnSuccess { dismiss() }
            }
        ) {
            PINBadge {
                if let url = request.homeUserAvatarURL.flatMap(URL.init(string:)) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case let .success(image):
                            image.resizable().scaledToFill()
                        default:
                            Image(systemName: "person.fill")
                                .font(.title)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Image(systemName: "person.fill")
                        .font(.title)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: model.plexPINError) { _, error in
            if error != nil { isSubmitting = false }
        }
        .onChange(of: pendingRequest?.id) { _, requestID in
            if requestID == nil, dismissOnSuccess {
                dismiss()
            }
        }
    }
}
#endif
