#if os(iOS)
import AniListService
import MALService
import SimklService
import SwiftUI
import TraktService

struct PlozziOSTrackerSettingsView: View {
    let appModel: PlozziOSAppModel

    var body: some View {
        Form {
            Section {
                Text(
                    "Connections are stored separately for each Plozz profile. "
                        + "Playback progress is sent to every connected tracker."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Section("Trakt") {
                TraktSettingsContent(service: appModel.traktService)
            }

            Section("Simkl") {
                SimklSettingsContent(service: appModel.simklService)
            }

            Section("AniList") {
                AniListSettingsContent(service: appModel.anilistService)
            }

            Section("MyAnimeList") {
                MALSettingsContent(service: appModel.malService)
            }
        }
        .navigationTitle("Trackers")
        .task {
            async let trakt: Void = appModel.traktService.refreshStatus()
            async let simkl: Void = appModel.simklService.refreshStatus()
            async let anilist: Void = appModel.anilistService.refreshStatus()
            async let mal: Void = appModel.malService.refreshStatus()
            _ = await (trakt, simkl, anilist, mal)
        }
    }
}

private struct TraktSettingsContent: View {
    let service: TraktService
    @Environment(\.openURL) private var openURL

    var body: some View {
        switch service.phase {
        case .unknown:
            loadingStatus
        case .unavailable:
            unavailableStatus
        case .disconnected:
            connectButton
        case let .connecting(userCode, verificationURL, _):
            Text("Enter this code on Trakt:")
                .foregroundStyle(.secondary)
            Text(userCode)
                .font(.title2.monospaced().weight(.semibold))
                .textSelection(.enabled)
            if let url = URL(string: verificationURL) {
                Button("Open Trakt") {
                    openURL(url)
                }
            }
            Button("Cancel", role: .cancel) {
                service.cancelConnect()
            }
        case let .connected(username):
            connectedStatus(username: username)
            Button("Disconnect", role: .destructive) {
                Task { await service.disconnect() }
            }
        case let .error(message):
            errorStatus(message)
            connectButton
        }
    }

    private var connectButton: some View {
        Button("Connect Trakt") {
            service.connect()
        }
    }
}

private struct SimklSettingsContent: View {
    let service: SimklService
    @Environment(\.openURL) private var openURL

    var body: some View {
        switch service.phase {
        case .unknown:
            loadingStatus
        case .unavailable:
            unavailableStatus
        case .disconnected:
            connectButton
        case let .connecting(userCode, verificationURL, _):
            Text("Enter this code on Simkl:")
                .foregroundStyle(.secondary)
            Text(userCode)
                .font(.title2.monospaced().weight(.semibold))
                .textSelection(.enabled)
            if let url = URL(string: verificationURL) {
                Button("Open Simkl") {
                    openURL(url)
                }
            }
            Button("Cancel", role: .cancel) {
                service.cancelConnect()
            }
        case let .connected(username):
            connectedStatus(username: username)
            Button("Disconnect", role: .destructive) {
                Task { await service.disconnect() }
            }
        case let .error(message):
            errorStatus(message)
            connectButton
        }
    }

    private var connectButton: some View {
        Button("Connect Simkl") {
            service.connect()
        }
    }
}

private struct AniListSettingsContent: View {
    let service: AniListService
    @Environment(\.openURL) private var openURL
    @State private var code = ""

    var body: some View {
        switch service.phase {
        case .unknown:
            loadingStatus
        case .unavailable:
            unavailableStatus
        case .disconnected:
            connectButton
        case let .awaitingToken(authorizationURL):
            authorizationForm(
                authorizationURL: authorizationURL,
                openButtonTitle: "Open AniList",
                submitButtonTitle: "Redeem Code"
            ) {
                Task { await service.submitToken(code) }
            }
        case let .connected(username):
            connectedStatus(username: username)
            Button("Disconnect", role: .destructive) {
                Task { await service.disconnect() }
            }
        case let .error(message):
            errorStatus(message)
            connectButton
        }
    }

    private var connectButton: some View {
        Button("Connect AniList") {
            code = ""
            service.connect()
        }
    }

    @ViewBuilder
    private func authorizationForm(
        authorizationURL: String,
        openButtonTitle: String,
        submitButtonTitle: String,
        submit: @escaping () -> Void
    ) -> some View {
        Text("Authorize in your browser, then enter the short code shown there.")
            .foregroundStyle(.secondary)
        if let url = URL(string: authorizationURL) {
            Button(openButtonTitle) {
                openURL(url)
            }
        }
        TextField("Authorization code", text: $code)
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
        Button(submitButtonTitle, action: submit)
            .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        Button("Cancel", role: .cancel) {
            service.cancelConnect()
        }
    }
}

private struct MALSettingsContent: View {
    let service: MALService
    @Environment(\.openURL) private var openURL
    @State private var code = ""

    var body: some View {
        switch service.phase {
        case .unknown:
            loadingStatus
        case .unavailable:
            unavailableStatus
        case .disconnected:
            connectButton
        case let .awaitingAuthorizationCode(authorizationURL):
            Text("Authorize in your browser, then enter the short code shown there.")
                .foregroundStyle(.secondary)
            if let url = URL(string: authorizationURL) {
                Button("Open MyAnimeList") {
                    openURL(url)
                }
            }
            TextField("Authorization code", text: $code)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            Button("Redeem Code") {
                service.submitAuthorizationCode(code)
            }
            .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {
                service.cancelConnect()
            }
        case let .connected(username):
            connectedStatus(username: username)
            Button("Disconnect", role: .destructive) {
                Task { await service.disconnect() }
            }
        case let .error(message):
            errorStatus(message)
            connectButton
        }
    }

    private var connectButton: some View {
        Button("Connect MyAnimeList") {
            code = ""
            service.connect()
        }
    }
}

private var loadingStatus: some View {
    HStack {
        ProgressView()
        Text("Checking connection…")
            .foregroundStyle(.secondary)
    }
}

private var unavailableStatus: some View {
    Label("Unavailable in this build", systemImage: "exclamationmark.triangle")
        .foregroundStyle(.secondary)
}

private func connectedStatus(username: String) -> some View {
    Label("Connected as \(username)", systemImage: "checkmark.circle.fill")
        .foregroundStyle(.green)
}

private func errorStatus(_ message: String) -> some View {
    Label(message, systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.red)
}
#endif
