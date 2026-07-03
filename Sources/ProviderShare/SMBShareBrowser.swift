import Foundation
import SMBClient
import CoreNetworking

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

    enum BrowseError: Error, CustomStringConvertible {
        case timedOut(String)
        var description: String {
            switch self { case .timedOut(let what): return "timed out \(what)" }
        }
    }

    private let host: String
    private let port: Int?
    private let share: String
    private let user: String
    private let password: String

    /// Guards against an unreachable host wedging the first browse forever
    /// (SMBClient's login/list have no timeout of their own).
    private let connectTimeout: TimeInterval = 12
    private let listTimeout: TimeInterval = 20

    private var client: SMBClient?

    /// Serial chain so `listDirectory` calls (which each connect-on-demand and
    /// then read the one shared session) never overlap across an `await`. Actor
    /// isolation alone does NOT provide this: two calls can both suspend inside
    /// `connectedClient()` seeing `client == nil` (double login/leak) or both be
    /// mid-`listDirectory` on the same session, which SMBClient isn't safe for.
    /// Every op waits for the previous one to finish before touching the session.
    private var listTail: Task<Void, Never> = Task {}

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
        let hostPort = port.map { ":\($0)" } ?? ""
        PlozzLog.boot("share: connecting to \(host)\(hostPort) share=\(share) user=\(user.isEmpty ? "<guest>" : user)")
        let client = port.map { SMBClient(host: host, port: $0) } ?? SMBClient(host: host)
        let account = user.isEmpty ? nil : user
        let secret = password.isEmpty ? nil : password
        let shareName = share
        try await Self.withTimeout(connectTimeout, "logging in to \(host)") {
            do {
                try await client.login(username: account ?? "guest", password: secret)
                PlozzLog.boot("share: login ok (\(account ?? "guest"))")
            } catch {
                PlozzLog.boot("share: login as \(account ?? "guest") failed (\(error)); retrying anonymously")
                try await client.login(username: nil, password: nil)
                PlozzLog.boot("share: anonymous login ok")
            }
        }
        try await Self.withTimeout(connectTimeout, "connecting to share \(share)") {
            try await client.connectShare(shareName)
        }
        PlozzLog.boot("share: connected to share \(shareName)")
        self.client = client
        return client
    }

    /// List one directory, `path` being share-relative (empty string == share
    /// root). Hidden/system entries and the `.`/`..` pseudo-entries are dropped.
    ///
    /// Serialised behind `listTail`: the connect (first call) and every listing
    /// run one-at-a-time on the single shared session, even when the scanner and
    /// a detail view request different folders concurrently.
    func listDirectory(_ path: String) async throws -> [Entry] {
        let previous = listTail
        let task = Task { () async throws -> [Entry] in
            // Wait for the prior op to finish before touching the session. Its
            // failure is irrelevant to ours; we only need the ordering.
            await previous.value
            let client = try await self.connectedClient()
            let files = try await Self.withTimeout(self.listTimeout, "listing \(path.isEmpty ? "<root>" : path)") {
                try await client.listDirectory(path: path)
            }
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
        // Extend the chain so the NEXT caller waits for this op regardless of how
        // it ends (and regardless of whether our caller cancels its await).
        listTail = Task { _ = await task.result }
        return try await task.value
    }

    /// Best-effort teardown. Safe to call more than once.
    func close() async {
        guard let client else { return }
        self.client = nil
        _ = try? await client.disconnectShare()
        _ = try? await client.logoff()
    }

    /// Races `operation` against a sleep so an unreachable host can't block the
    /// browse indefinitely. The loser is cancelled; SMBClient may not honour
    /// cancellation mid-flight, but the caller still unblocks with an error.
    private static func withTimeout<T: Sendable>(
        _ seconds: TimeInterval,
        _ what: String,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw BrowseError.timedOut(what)
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw BrowseError.timedOut(what)
            }
            return result
        }
    }
}
