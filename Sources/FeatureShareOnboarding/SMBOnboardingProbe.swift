import CoreModels
import Foundation
import MediaTransportCore
import MediaTransportSMB
import ProviderShare

public struct SMBOnboardingLocation: Sendable, Equatable {
    public let name: String
    /// A share name for a top-level location, or a path relative to the selected
    /// share for a directory.
    public let path: String

    public init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}

public enum SMBOnboardingListing: Sendable, Equatable {
    case success([SMBOnboardingLocation])
    case authenticationRequired
    case credentialsRejected
    case unreachable
    case failed(String)
    case cancelled
}

public protocol SMBOnboardingProbing: Sendable {
    func listShares(
        host: String,
        port: Int?,
        username: String,
        password: String
    ) async -> SMBOnboardingListing

    func listDirectories(
        host: String,
        port: Int?,
        share: String,
        username: String,
        password: String,
        relativePath: String
    ) async -> SMBOnboardingListing
}

/// Uses the same SMB adapter as scanning and playback for folder browsing, so
/// onboarding cannot drift onto different authentication or path semantics.
public struct SMBOnboardingProbe: SMBOnboardingProbing {
    public init() {}

    public func listShares(
        host: String,
        port: Int?,
        username: String,
        password: String
    ) async -> SMBOnboardingListing {
        do {
            let shares = try await SMBShareEnumerator.listShares(
                host: host,
                port: port,
                username: username,
                password: password
            )
            return .success(
                shares.map { SMBOnboardingLocation(name: $0, path: $0) }
            )
        } catch let error as SMBShareEnumerator.ListError {
            switch error {
            case .authenticationRequired:
                return .authenticationRequired
            case .credentialsRejected:
                return .credentialsRejected
            case .unreachable, .timedOut:
                return .unreachable
            case .failed(let reason):
                return .failed(reason)
            }
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    public func listDirectories(
        host: String,
        port: Int?,
        share: String,
        username: String,
        password: String,
        relativePath: String
    ) async -> SMBOnboardingListing {
        let credential: SMBMediaTransportCredential =
            username.isEmpty && password.isEmpty
                ? .anonymous
                : .password(username: username, password: password)
        let adapter = SMBMediaTransportAdapter { _, _ in
            SMBMediaTransportConfiguration(credential: credential)
        }

        do {
            let endpoint = try MediaTransportEndpointIdentity(
                transportIdentifier: MediaShareTransportKind.smb.rawValue,
                host: host,
                port: port,
                rootPath: "/\(share)"
            )
            let revision = CredentialRevision()
            let session = try await adapter.connect(
                for: MediaTransportSessionKey(
                    accountID: "smb-onboarding",
                    credentialRevision: revision,
                    endpoint: endpoint,
                    trustRevision: UUID(
                        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
                    ),
                    role: .metadata
                )
            )
            defer { Task { await session.shutdown() } }
            let entries = try await session.fileSystem.list(
                relativePath: relativePath
            )
            return .success(
                entries
                    .filter { $0.kind == .directory }
                    .map {
                        SMBOnboardingLocation(
                            name: ($0.relativePath as NSString).lastPathComponent,
                            path: $0.relativePath
                        )
                    }
                    .sorted {
                        $0.name.localizedCaseInsensitiveCompare($1.name)
                            == .orderedAscending
                    }
            )
        } catch is CancellationError {
            return .cancelled
        } catch let error as MediaTransportError {
            switch error {
            case .authentication, .permissionDenied:
                return username.isEmpty && password.isEmpty
                    ? .authenticationRequired
                    : .credentialsRejected
            case .transport, .timeout, .resourceBusy:
                return .unreachable
            case .cancelled:
                return .cancelled
            case .invalidInput(let reason),
                 .unsupportedCapability(let reason),
                 .unsupportedRange(let reason),
                 .trust(let reason),
                 .protocolViolation(let reason),
                 .sourceChanged(let reason):
                return .failed(reason)
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
