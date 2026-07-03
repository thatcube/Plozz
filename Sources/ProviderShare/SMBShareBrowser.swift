import Foundation
import SMBClient

/// Thin async wrapper over `SMBClient` for **browsing** a share: login, connect
/// to the tree, and enumerate directories. Playback byte-reads are a separate
/// concern handled by the engine's `SMBConnection`; this type only lists.
///
/// One browser owns one live `SMBClient`/session. It's an `actor` so concurrent
/// `listDirectory` calls from the scanner serialise onto a single connection
/// (the underlying session isn't safe for parallel in-flight requests).
actor SMBShareBrowser {
    struct Entry: Sendable {
        let name: String
        let isDirectory: Bool
        let size: UInt64
        let modifiedAt: Date
    }

    private let host: String
    private let port: Int?
    private let share: String
    private let user: String
    private let password: String

    private var client: SMBClient?

    init(host: String, port: Int?, share: String, user: String, password: String) {
        self.host = host
        self.port = port
        self.share = share
        self.user = user
        self.password = password
    }

    /// Establish the session + tree connection if not already connected. Mirrors
    /// the engine's guest/anonymous fallback so a public share works with no
    /// explicit account.
    private func connectedClient() async throws -> SMBClient {
        if let client { return client }
        let client = port.map { SMBClient(host: host, port: $0) } ?? SMBClient(host: host)
        let account = user.isEmpty ? nil : user
        let secret = password.isEmpty ? nil : password
        do {
            try await client.login(username: account ?? "guest", password: secret)
        } catch {
            try await client.login(username: nil, password: nil)
        }
        try await client.connectShare(share)
        self.client = client
        return client
    }

    /// List one directory, `path` being share-relative (empty string == share
    /// root). Hidden/system entries and the `.`/`..` pseudo-entries are dropped.
    func listDirectory(_ path: String) async throws -> [Entry] {
        let client = try await connectedClient()
        let files = try await client.listDirectory(path: path)
        return files.compactMap { file in
            guard file.name != ".", file.name != "..",
                  !file.isHidden, !file.isSystem else { return nil }
            return Entry(
                name: file.name,
                isDirectory: file.isDirectory,
                size: file.size,
                modifiedAt: file.lastWriteTime
            )
        }
    }

    /// Best-effort teardown. Safe to call more than once.
    func close() async {
        guard let client else { return }
        self.client = nil
        _ = try? await client.disconnectShare()
        _ = try? await client.logoff()
    }
}
