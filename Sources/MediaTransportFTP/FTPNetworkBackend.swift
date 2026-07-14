import CoreModels
import Foundation
import MediaTransportCore

/// The real FTP protocol engine over `NWConnection`. An actor that serializes
/// logical operations (an FTP control channel is single-command-at-a-time) and
/// keeps a contiguous playback transfer streaming on one data connection,
/// restarting it with `REST`+`RETR` on a discontiguous seek.
///
/// **TLS scope on tvOS:** `NWConnection` has no StartTLS, so *explicit* FTPS
/// (`AUTH TLS`) cannot be performed — `connect()` rejects it. *Implicit* FTPS
/// (TLS from connect, conventionally port 990) and plain FTP are supported.
actor FTPNetworkBackend: FTPBackend {
    private struct ActiveTransfer {
        let socket: FTPSocket
        var nextOffset: Int64
        var reachedEOF: Bool
    }

    private let target: FTPConnectionTarget
    private let configuration: FTPMediaTransportConfiguration

    private var control: FTPControlConnection?
    private var features: Set<String> = []
    private var activeTransfer: ActiveTransfer?
    private var isClosed = false

    // Async serialization gate (actor methods are reentrant across awaits).
    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private static let maxListingBytes = 8 * 1_024 * 1_024

    init(target: FTPConnectionTarget, configuration: FTPMediaTransportConfiguration) {
        self.target = target
        self.configuration = configuration
    }

    // MARK: - Serialization

    private func acquire() async {
        if !isBusy {
            isBusy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            isBusy = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    // MARK: - Connect / login

    func connect() async throws {
        guard control == nil, !isClosed else {
            throw MediaTransportError.invalidInput(reason: "FTP backend already connected")
        }
        if configuration.security.negotiatesExplicitTLS {
            // Explicit FTPS needs to upgrade an established plaintext socket to
            // TLS (RFC 4217 AUTH TLS). Network.framework offers no StartTLS on
            // tvOS, so this is honestly unsupported rather than silently
            // downgraded. Implicit FTPS (990) or plain FTP are the options.
            throw MediaTransportError.unsupportedCapability(
                "FTP explicit TLS (AUTH TLS) is unavailable on tvOS"
            )
        }

        let parameters = FTPTLSParameters.make(
            security: configuration.security,
            trustPolicy: configuration.trustPolicy
        )
        let socket = FTPSocket(host: target.host, port: target.port, parameters: parameters)
        do {
            try await socket.start()
        } catch {
            socket.cancel()
            throw mapFTPError(error)
        }
        let control = FTPControlConnection(socket: socket)
        self.control = control

        do {
            let greeting = try await control.readReply()
            guard greeting.code == 220 else {
                throw FTPProtocolError.unexpectedReply(code: greeting.code)
            }
            try await loadFeatures(control)
            if features.contains("UTF8") {
                _ = try? await control.send("OPTS UTF8 ON")
            }
            try await login(control)
            if configuration.security.usesTLS {
                // Protect the data channel too (RFC 4217): PBSZ 0 then PROT P.
                _ = try? await control.send("PBSZ 0")
                let prot = try await control.send("PROT P")
                guard prot.isPositiveCompletion else {
                    throw FTPProtocolError.unexpectedReply(code: prot.code)
                }
            }
            try await control.sendExpectingCompletion("TYPE I")
        } catch {
            control.cancel()
            self.control = nil
            throw mapFTPError(error)
        }
    }

    func supportsRestart() async -> Bool {
        // `REST STREAM` in FEAT is the server's affirmation of restart support.
        features.contains("REST")
    }

    private func loadFeatures(_ control: FTPControlConnection) async throws {
        guard let reply = try? await control.send("FEAT"), reply.code == 211 else {
            features = []
            return
        }
        var found: Set<String> = []
        for line in reply.text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let token = trimmed.split(separator: " ").first else { continue }
            found.insert(token.uppercased())
        }
        features = found
    }

    private func login(_ control: FTPControlConnection) async throws {
        let (user, pass) = configuration.credential.loginPair
        let userReply = try await control.send("USER \(user)")
        if userReply.code == 331 || userReply.isPositiveIntermediate {
            let passReply = try await control.send("PASS \(pass)")
            guard passReply.isPositiveCompletion else {
                throw FTPProtocolError.unexpectedReply(code: passReply.code)
            }
        } else if !userReply.isPositiveCompletion {
            throw FTPProtocolError.unexpectedReply(code: userReply.code)
        }
    }

    // MARK: - Passive data channel

    private func openPassiveDataConnection() async throws -> FTPSocket {
        let port = try await negotiatePassivePort()
        let parameters = FTPTLSParameters.make(
            security: configuration.security,
            trustPolicy: configuration.trustPolicy
        )
        // Always connect the data channel to the control host (NAT-hairpin-safe;
        // the PASV reply's advertised IP is deliberately ignored — see
        // FTPPassivePort doc).
        let socket = FTPSocket(host: target.host, port: port, parameters: parameters)
        do {
            try await socket.start()
        } catch {
            socket.cancel()
            throw FTPProtocolError.dataConnectionFailed
        }
        return socket
    }

    private func negotiatePassivePort() async throws -> Int {
        guard let control else { throw MediaTransportError.transport(code: -1) }
        // Prefer EPSV (IPv6-capable + modern); fall back to PASV (IPv4).
        if let epsv = try? await control.send("EPSV"), epsv.code == 229,
           let parsed = try? FTPPassiveParser.parseEPSV(epsv.text) {
            return parsed.port
        }
        let pasv = try await control.send("PASV")
        guard pasv.code == 227 else {
            throw FTPProtocolError.passiveModeUnavailable
        }
        return try FTPPassiveParser.parsePASV(pasv.text).port
    }

    // MARK: - Browse

    func list(path: String) async throws -> [FTPBackendEntry] {
        await acquire()
        defer { release() }
        guard let control else { throw MediaTransportError.transport(code: -1) }

        let dataSocket = try await openPassiveDataConnection()
        let useMLSD = features.contains("MLSD")
        let command = useMLSD ? "MLSD \(path)" : "LIST \(path)"
        let reply = try await control.send(command)
        guard reply.isPositivePreliminary || reply.isPositiveCompletion else {
            dataSocket.cancel()
            throw FTPProtocolError.unexpectedReply(code: reply.code)
        }
        let data = try await readAll(from: dataSocket, cap: Self.maxListingBytes)
        dataSocket.cancel()
        if reply.isPositivePreliminary {
            let final = try await control.readReply()
            guard final.isPositiveCompletion else {
                throw FTPProtocolError.unexpectedReply(code: final.code)
            }
        }

        let text = String(decoding: data, as: UTF8.self)
        let listings = useMLSD
            ? FTPListParser.parseMLSD(text)
            : FTPListParser.parseLIST(text)
        return listings.map {
            FTPBackendEntry(name: $0.name, kind: $0.kind, size: $0.size, modifiedAt: $0.modifiedAt)
        }
    }

    func stat(path: String) async throws -> FTPBackendEntry {
        await acquire()
        defer { release() }
        guard let control else { throw MediaTransportError.transport(code: -1) }
        let name = lastComponent(of: path)

        if features.contains("MLST"),
           let reply = try? await control.send("MLST \(path)"),
           reply.isPositiveCompletion,
           let listing = parseMLSTFacts(reply.text) {
            return FTPBackendEntry(
                name: name,
                kind: listing.kind,
                size: listing.kind == .directory ? nil : listing.size,
                modifiedAt: listing.modifiedAt
            )
        }

        // Fallback: SIZE identifies a file; otherwise probe as a directory.
        let sizeReply = try await control.send("SIZE \(path)")
        if sizeReply.code == 213,
           let size = Int64(sizeReply.text.trimmingCharacters(in: .whitespaces)) {
            let mtime = try await fetchMDTM(path, on: control)
            return FTPBackendEntry(name: name, kind: .file, size: size, modifiedAt: mtime)
        }

        let cwd = try await control.send("CWD \(path)")
        guard cwd.isPositiveCompletion else {
            throw FTPProtocolError.unexpectedReply(code: cwd.code)
        }
        // Restore the working directory to the root to avoid state drift.
        _ = try? await control.send("CWD \(target.rootPath)")
        return FTPBackendEntry(name: name, kind: .directory, size: nil, modifiedAt: nil)
    }

    func readSmallFile(path: String, maximumBytes: Int) async throws -> Data {
        await acquire()
        defer { release() }
        guard let control else { throw MediaTransportError.transport(code: -1) }

        let dataSocket = try await openPassiveDataConnection()
        let retr = try await control.send("RETR \(path)")
        guard retr.isPositivePreliminary else {
            dataSocket.cancel()
            throw FTPProtocolError.unexpectedReply(code: retr.code)
        }
        // Read one byte past the bound so an over-large file is detected rather
        // than silently truncated.
        let data = try await readAll(from: dataSocket, cap: maximumBytes + 1)
        dataSocket.cancel()
        _ = try? await control.readReply()
        guard data.count <= maximumBytes else {
            throw MediaTransportError.invalidInput(reason: "FTP file exceeds bound")
        }
        return data
    }

    // MARK: - Ranged playback read

    /// Drift detection over FTP (deliberate, documented policy):
    ///
    /// The filesystem-transport family fails closed if a file changes underneath
    /// in-flight playback. FTP has no ETag and — unlike SMB's per-read fstat — no
    /// cheap per-read stat: `SIZE`/`MDTM` are separate control commands that
    /// cannot be issued while a `RETR` transfer occupies the control channel. So
    /// FTP re-validates `SIZE`+`MDTM` and fails closed with `.sourceChanged` at
    /// two boundaries — at `openSource` (see the filesystem) and again on **every
    /// seek** (a discontiguous read restarts the transfer, so `validateSize` runs
    /// before each new `REST`+`RETR`). It does **not** re-validate mid-contiguous
    /// stream, because doing so would require aborting the active transfer. Net:
    /// drift is caught at open and at each seek; a change during an uninterrupted
    /// linear read is not detected (and would surface as an early EOF / short
    /// read, never as mixed-version bytes). This is a conscious limitation of the
    /// protocol, kept explicit so the family's fail-closed story stays coherent.
    func read(
        path: String,
        at offset: Int64,
        length: Int,
        expected: RemoteFileRepresentation
    ) async throws -> Data {
        await acquire()
        defer { release() }

        if let active = activeTransfer, active.nextOffset == offset, !active.reachedEOF {
            return try await continueRead(length: length)
        }
        try await abortActiveTransfer()
        try await validateSize(path: path, expected: expected)
        try await startTransfer(path: path, offset: offset)
        return try await continueRead(length: length)
    }

    private func validateSize(path: String, expected: RemoteFileRepresentation) async throws {
        guard let control else { throw MediaTransportError.transport(code: -1) }
        let reply = try await control.send("SIZE \(path)")
        guard reply.code == 213,
              let size = Int64(reply.text.trimmingCharacters(in: .whitespaces)) else {
            throw MediaTransportError.sourceChanged(reason: "FTP size unavailable")
        }
        guard size == expected.size else {
            throw MediaTransportError.sourceChanged(reason: "FTP size changed")
        }
        if expected.identity.kind == .modificationTime,
           let expectedDate = expected.identity.modifiedAt,
           let current = try await fetchMDTM(path, on: control),
           current != expectedDate {
            throw MediaTransportError.sourceChanged(reason: "FTP mtime changed")
        }
    }

    private func startTransfer(path: String, offset: Int64) async throws {
        guard let control else { throw MediaTransportError.transport(code: -1) }
        let dataSocket = try await openPassiveDataConnection()
        if offset > 0 {
            let rest = try await control.send("REST \(offset)")
            guard rest.code == 350 else {
                dataSocket.cancel()
                throw FTPProtocolError.unexpectedReply(code: rest.code)
            }
        }
        let retr = try await control.send("RETR \(path)")
        guard retr.isPositivePreliminary else {
            dataSocket.cancel()
            throw FTPProtocolError.unexpectedReply(code: retr.code)
        }
        activeTransfer = ActiveTransfer(socket: dataSocket, nextOffset: offset, reachedEOF: false)
    }

    private func continueRead(length: Int) async throws -> Data {
        guard var active = activeTransfer else { return Data() }
        var accumulated = Data()
        while accumulated.count < length {
            let remaining = length - accumulated.count
            let (chunk, isComplete) = try await active.socket.receive(maximumLength: remaining)
            if !chunk.isEmpty { accumulated.append(chunk) }
            if isComplete {
                active.reachedEOF = true
                break
            }
            if chunk.isEmpty { break }
        }
        active.nextOffset += Int64(accumulated.count)
        activeTransfer = active

        if active.reachedEOF {
            active.socket.cancel()
            activeTransfer = nil
            // Drain the transfer-complete (226) reply so the control channel
            // stays in sync for the next command.
            if let control { _ = try? await control.readReply() }
        }
        return accumulated
    }

    private func abortActiveTransfer() async throws {
        guard let active = activeTransfer else { return }
        activeTransfer = nil
        active.socket.cancel()
        guard let control else { return }
        // Best-effort ABOR + drain: a partial RETR typically yields a 426
        // (aborted) followed by a 226/225 (abort ok). Tolerate either framing.
        if let reply = try? await control.send("ABOR") {
            if reply.isPositivePreliminary || reply.code == 426 || reply.isTransientNegative {
                _ = try? await control.readReply()
            }
        }
    }

    // MARK: - Helpers

    private func fetchMDTM(_ path: String, on control: FTPControlConnection) async throws -> Date? {
        guard let reply = try? await control.send("MDTM \(path)"), reply.code == 213 else {
            return nil
        }
        return FTPListParser.parseMLSDTimestamp(reply.text.trimmingCharacters(in: .whitespaces))
    }

    private func readAll(from socket: FTPSocket, cap: Int) async throws -> Data {
        var accumulated = Data()
        while accumulated.count < cap {
            let (chunk, isComplete) = try await socket.receive(maximumLength: 64 * 1_024)
            if !chunk.isEmpty { accumulated.append(chunk) }
            if isComplete { break }
            if chunk.isEmpty { break }
        }
        return accumulated
    }

    private func lastComponent(of path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    /// Extracts type/size/modify from an `MLST` reply. The fact line is
    /// ` facts SP pathname` (leading space); `FTPReplyParser` has already
    /// stripped the `250`/`250-` framing, so scan for the line carrying facts.
    private func parseMLSTFacts(_ text: String) -> FTPListing? {
        for line in text.split(separator: "\n") {
            let trimmed = String(line).trimmingCharacters(in: .whitespaces)
            guard trimmed.contains("=") else { continue }
            if let listing = FTPListParser.parseMLSDLine(trimmed) {
                return listing
            }
        }
        return nil
    }

    func shutdown() async {
        await acquire()
        defer { release() }
        guard !isClosed else { return }
        isClosed = true
        if let active = activeTransfer {
            active.socket.cancel()
            activeTransfer = nil
        }
        if let control {
            _ = try? await control.send("QUIT")
            control.cancel()
        }
        control = nil
    }
}
