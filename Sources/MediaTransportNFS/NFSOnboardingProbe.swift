import CoreModels
import Foundation
import MediaTransportCore
import TransportNFS

/// One browsable directory at the NFS pick-location step (an export root, or a
/// subfolder within a mounted export).
public struct NFSDirectoryItem: Sendable, Equatable {
    public let name: String
    /// For an export: the export dirpath. For a subfolder: the export path joined
    /// with the subfolder — a deeper path the saved share mounts directly.
    public let path: String

    public init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}

/// The outcome of an NFS onboarding listing (exports or subfolders).
public enum NFSDirectoryListing: Sendable, Equatable {
    case success([NFSDirectoryItem])
    case unreachable
    case permissionDenied
    case failed(String)
}

/// A testable seam for the NFS add-share browser. `listExports` offers the
/// server's advertised exports (so the user picks a real path instead of guessing
/// one); `listDirectories` mounts a chosen export and lists its child directories
/// so the user can drill into a subfolder to scope the scan. Tests substitute a
/// stub; the real probe drives the pure-Swift `NFSClient` (reconnects per call —
/// onboarding is low-frequency).
public protocol NFSOnboardingProbing: Sendable {
    func listExports(host: String, port: Int?) async -> NFSDirectoryListing
    func listDirectories(
        host: String,
        port: Int?,
        exportPath: String,
        relativePath: String
    ) async -> NFSDirectoryListing
}

public struct NFSOnboardingProbe: NFSOnboardingProbing {
    public init() {}

    public func listExports(host: String, port: Int?) async -> NFSDirectoryListing {
        let client = NFSClient(host: host, nfsPort: port.flatMap { UInt16(exactly: $0) })
        do {
            let exports = try await client.listExports()
            let items = exports
                .map { NFSDirectoryItem(name: $0, path: $0) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return .success(items)
        } catch {
            return Self.classify(error)
        }
    }

    public func listDirectories(
        host: String,
        port: Int?,
        exportPath: String,
        relativePath: String
    ) async -> NFSDirectoryListing {
        let client = NFSClient(host: host, nfsPort: port.flatMap { UInt16(exactly: $0) })
        do {
            let session = try await client.mount(exportPath: exportPath)
            defer { Task { await session.shutdown() } }
            let entries = try await session.list(relativePath: relativePath)
            // The persisted share for a subfolder mounts the DEEPER path directly
            // (export + subpath); consumer NAS allow subtree mounts. Join the
            // export root with the relative subpath so each item is a mountable
            // export path.
            let base = joinedExportBase(exportPath: exportPath, relativePath: relativePath)
            let items = entries
                .filter { $0.attributes?.isDirectory == true && $0.name != "." && $0.name != ".." }
                .map { NFSDirectoryItem(name: $0.name, path: "\(base)/\($0.name)") }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return .success(items)
        } catch {
            return Self.classify(error)
        }
    }

    private func joinedExportBase(exportPath: String, relativePath: String) -> String {
        let export = exportPath.hasSuffix("/") ? String(exportPath.dropLast()) : exportPath
        let rel = relativePath == "/" ? "" : (relativePath.hasPrefix("/") ? relativePath : "/" + relativePath)
        let joined = export + rel
        return joined.hasSuffix("/") ? String(joined.dropLast()) : joined
    }

    private static func classify(_ error: Error) -> NFSDirectoryListing {
        guard let nfsError = error as? NFSError else {
            return .failed("Couldn’t reach this NFS server.")
        }
        switch nfsError {
        case .connectionFailed, .timeout:
            return .unreachable
        case .rpcDenied(let authError):
            return authError ? .permissionDenied : .failed("The NFS server rejected the request.")
        case .mountFailed(let status):
            switch status {
            case .accessDenied, .perm:
                return .permissionDenied
            case .notSupported:
                return .failed("This server doesn’t support listing exports. Type the export path instead.")
            default:
                return .failed("Couldn’t mount that export.")
            }
        case .status(let status):
            switch status {
            case .accessDenied, .perm:
                return .permissionDenied
            default:
                return .failed("The NFS server reported an error.")
            }
        case .cancelled:
            return .failed("The request was cancelled.")
        default:
            return .failed("Couldn’t reach this NFS server.")
        }
    }
}
