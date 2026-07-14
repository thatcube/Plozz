import CoreModels
import Foundation
import MediaTransportCore
@testable import MediaTransportFTP

/// In-memory FTP server for hermetic tests: an absolute-path → node map with
/// ranged reads and change detection, standing in for a real server so the
/// adapter/filesystem/byte-source path runs without a socket.
final class FakeFTPServer: @unchecked Sendable {
    struct Node {
        let kind: RemoteFileEntryKind
        let size: Int64?
        let mtime: Date?
        let data: Data?
    }

    private let lock = NSLock()
    private var nodes: [String: Node] = [:]
    var connectError: Error?
    /// Whether the fake server affirms `REST` (seekable). Default true.
    var restartSupported = true

    func addDirectory(path: String, mtime: Date? = nil) {
        lock.withLock {
            nodes[path] = Node(kind: .directory, size: nil, mtime: mtime, data: nil)
        }
    }

    func addFile(path: String, data: Data, mtime: Date?) {
        lock.withLock {
            nodes[path] = Node(kind: .file, size: Int64(data.count), mtime: mtime, data: data)
        }
    }

    func node(_ path: String) throws -> Node {
        try lock.withLock {
            guard let node = nodes[path] else {
                throw FTPProtocolError.unexpectedReply(code: 550)
            }
            return node
        }
    }

    func stat(_ path: String) throws -> FTPBackendEntry {
        let node = try node(path)
        return FTPBackendEntry(
            name: path.split(separator: "/").last.map(String.init) ?? path,
            kind: node.kind,
            size: node.size,
            modifiedAt: node.mtime
        )
    }

    func children(of directory: String) -> [FTPBackendEntry] {
        let prefix = directory == "/" ? "/" : directory + "/"
        let dropCount = directory == "/" ? 1 : directory.count + 1
        return lock.withLock {
            nodes.compactMap { path, node -> FTPBackendEntry? in
                guard path != directory, path.hasPrefix(prefix) else { return nil }
                let rest = String(path.dropFirst(dropCount))
                guard !rest.isEmpty, !rest.contains("/") else { return nil }
                return FTPBackendEntry(name: rest, kind: node.kind, size: node.size, modifiedAt: node.mtime)
            }
        }
    }
}

/// A ``FTPBackend`` backed by a ``FakeFTPServer``. Each connection shares the
/// same server instance so per-cursor playback backends see the same files.
final class FakeFTPBackend: FTPBackend, @unchecked Sendable {
    private let server: FakeFTPServer

    init(server: FakeFTPServer) {
        self.server = server
    }

    func connect() async throws {
        if let error = server.connectError { throw error }
    }

    func supportsRestart() async -> Bool {
        server.restartSupported
    }

    func list(path: String) async throws -> [FTPBackendEntry] {
        server.children(of: path)
    }

    func stat(path: String) async throws -> FTPBackendEntry {
        try server.stat(path)
    }

    func readSmallFile(path: String, maximumBytes: Int) async throws -> Data {
        let node = try server.node(path)
        let data = node.data ?? Data()
        guard data.count <= maximumBytes else {
            throw MediaTransportError.invalidInput(reason: "FTP file exceeds bound")
        }
        return data
    }

    func read(
        path: String,
        at offset: Int64,
        length: Int,
        expected: RemoteFileRepresentation
    ) async throws -> Data {
        let node = try server.node(path)
        try validateFTPRepresentation(
            size: node.size ?? -1,
            modifiedAt: node.mtime,
            against: expected
        )
        let data = node.data ?? Data()
        guard offset >= 0, offset < Int64(data.count), length > 0 else { return Data() }
        let start = Int(offset)
        let end = min(start + length, data.count)
        return data.subdata(in: start..<end)
    }

    func shutdown() async {}
}
