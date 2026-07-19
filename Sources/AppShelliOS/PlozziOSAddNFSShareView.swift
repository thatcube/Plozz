#if os(iOS)
import Foundation
import MediaTransportNFS
import SwiftUI

struct PlozziOSAddNFSShareView: View {
    @Environment(\.dismiss) private var dismiss

    let appModel: PlozziOSAppModel

    @State private var host = ""
    @State private var portText = ""
    @State private var exportPath = ""
    @State private var displayName = ""
    @State private var discoveredItems: [NFSDirectoryItem] = []
    @State private var discoveryTitle = "Exports"
    @State private var isLoading = false
    @State private var errorMessage: String?

    private let probe = NFSOnboardingProbe()

    var body: some View {
        Form {
            Section("NFS server") {
                TextField("Host or IP address", text: $host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Port (optional)", text: $portText)
                    .keyboardType(.numberPad)
                Button("Find Exports", systemImage: "magnifyingglass") {
                    Task { await findExports() }
                }
                .disabled(!canProbe || isLoading)
            }

            Section("Location") {
                TextField("Export path", text: $exportPath, prompt: Text("/volume/media"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Browse Folders", systemImage: "folder") {
                    Task { await browseFolders() }
                }
                .disabled(!canBrowse || isLoading)
            }

            if isLoading {
                Section {
                    HStack {
                        ProgressView()
                        Text("Connecting…")
                    }
                }
            } else if !discoveredItems.isEmpty {
                Section(discoveryTitle) {
                    ForEach(discoveredItems, id: \.path) { item in
                        Button {
                            exportPath = item.path
                        } label: {
                            HStack {
                                Label(item.name, systemImage: "folder")
                                Spacer()
                                if exportPath == item.path {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }

            Section {
                TextField("Name (optional)", text: $displayName)
            } header: {
                Text("Display")
            } footer: {
                Text("Plozz scans the selected export for movies and TV episodes. NFS uses your server’s existing network permissions.")
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Add NFS Share")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    if appModel.addNFSShare(
                        host: host,
                        port: parsedPort,
                        exportPath: exportPath,
                        displayName: displayName
                    ) {
                        dismiss()
                    } else {
                        errorMessage = appModel.accountError
                    }
                }
                .disabled(!canSave || isLoading)
            }
        }
    }

    private var parsedPort: Int? {
        let trimmed = portText.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : Int(trimmed)
    }

    private var hasValidPort: Bool {
        let trimmed = portText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return true }
        guard let port = Int(trimmed) else { return false }
        return (1...65_535).contains(port)
    }

    private var canProbe: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty && hasValidPort
    }

    private var canBrowse: Bool {
        canProbe && !exportPath.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var canSave: Bool {
        canBrowse
    }

    @MainActor
    private func findExports() async {
        isLoading = true
        errorMessage = nil
        discoveredItems = []
        defer { isLoading = false }

        switch await probe.listExports(
            host: host.trimmingCharacters(in: .whitespaces),
            port: parsedPort
        ) {
        case let .success(items):
            discoveryTitle = "Exports"
            discoveredItems = items
            if items.isEmpty {
                errorMessage = "This server didn’t advertise any NFS exports. You can type a path manually."
            }
        case .unreachable:
            errorMessage = "Couldn’t reach this NFS server."
        case .permissionDenied:
            errorMessage = "The server denied access to its NFS exports."
        case let .failed(message):
            errorMessage = message
        }
    }

    @MainActor
    private func browseFolders() async {
        isLoading = true
        errorMessage = nil
        discoveredItems = []
        defer { isLoading = false }

        switch await probe.listDirectories(
            host: host.trimmingCharacters(in: .whitespaces),
            port: parsedPort,
            exportPath: exportPath,
            relativePath: "/"
        ) {
        case let .success(items):
            discoveryTitle = "Folders"
            discoveredItems = items
            if items.isEmpty {
                errorMessage = "No folders were found inside this export."
            }
        case .unreachable:
            errorMessage = "Couldn’t reach this NFS server."
        case .permissionDenied:
            errorMessage = "The server denied access to this export."
        case let .failed(message):
            errorMessage = message
        }
    }
}
#endif
