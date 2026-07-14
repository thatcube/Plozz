import CoreModels
import Foundation
import MediaTransportCore

/// One browsable directory at the FTP pick-location step.
public struct FTPDirectoryItem: Sendable, Equatable {
    public let name: String
    /// Absolute, server-rooted path (the parent joined with `name`).
    public let path: String

    public init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}

/// The outcome of listing an FTP directory during onboarding.
public enum FTPDirectoryListing: Sendable, Equatable {
    case success([FTPDirectoryItem])
    case authenticationFailed
    case unreachable
    case failed(String)
    case cancelled
}

/// A testable seam for the FTP add-share folder browser: connect + `LIST` a path,
/// returning its child directories so the user can drill into a subfolder to use
/// as the share root. Tests substitute a stub; the real probe drives a one-shot
/// `FTPNetworkBackend` connection (reconnects per call — onboarding is
/// low-frequency, mirroring the WebDAV/SFTP browsers' stateless model).
public protocol FTPOnboardingProbing: Sendable {
    func listDirectories(
        host: String,
        port: Int?,
        isImplicitTLS: Bool,
        username: String,
        password: String,
        trustPinSHA256: Data?,
        path: String
    ) async -> FTPDirectoryListing
}

public struct FTPOnboardingProbe: FTPOnboardingProbing {
    public init() {}

    public func listDirectories(
        host: String,
        port: Int?,
        isImplicitTLS: Bool,
        username: String,
        password: String,
        trustPinSHA256: Data?,
        path: String
    ) async -> FTPDirectoryListing {
        let security: FTPSecurity = isImplicitTLS ? .implicitTLS : .plaintext
        let credential: FTPCredential = (username.isEmpty && password.isEmpty)
            ? .anonymous
            : .password(username: username, password: password)
        let trustPolicy: FTPTrustPolicy = trustPinSHA256
            .map { .pinnedLeaf(sha256: Array($0), revision: UUID()) } ?? .system
        let configuration = FTPMediaTransportConfiguration(
            credential: credential,
            security: security,
            trustPolicy: trustPolicy
        )
        do {
            let endpoint = try MediaTransportEndpointIdentity(
                transportIdentifier: isImplicitTLS ? "ftps" : "ftp",
                host: host,
                port: port,
                rootPath: "/"
            )
            let target = try FTPConnectionTarget(endpoint: endpoint, security: security)
            let backend = FTPNetworkBackend(target: target, configuration: configuration)
            defer { Task { await backend.shutdown() } }
            try await backend.connect()
            let entries = try await backend.list(path: path)
            let base = path == "/" ? "" : (path.hasSuffix("/") ? String(path.dropLast()) : path)
            let items = entries
                .filter { $0.kind == .directory && $0.name != "." && $0.name != ".." }
                .map { FTPDirectoryItem(name: $0.name, path: "\(base)/\($0.name)") }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return .success(items)
        } catch {
            return Self.classify(error)
        }
    }

    private static func classify(_ error: Error) -> FTPDirectoryListing {
        guard let transportError = error as? MediaTransportError else {
            return .failed("Couldn’t list this folder.")
        }
        switch transportError {
        case .authentication, .permissionDenied:
            return .authenticationFailed
        case .cancelled:
            return .cancelled
        case .transport, .timeout, .resourceBusy:
            return .unreachable
        case .trust(let reason),
             .protocolViolation(let reason),
             .invalidInput(let reason),
             .unsupportedRange(let reason),
             .sourceChanged(let reason):
            return .failed(reason)
        case .unsupportedCapability(let reason):
            return .failed(reason)
        }
    }
}
