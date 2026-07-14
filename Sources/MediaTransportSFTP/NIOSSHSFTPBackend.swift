import Crypto
import Foundation
import MediaTransportCore
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSH

/// The production ``SFTPTransportBackend``: it drives Apple's swift-nio-ssh for
/// the SSH transport (key exchange, ciphers, host-key crypto) and layers the
/// thin SFTP v3 request/response client (``SFTPWireProtocol``) on top over the
/// `sftp` subsystem channel. It owns exactly one SSH connection; shutting it
/// down tears down that connection and its event-loop group.
///
/// swift-nio-ssh owns everything security-critical; this type only frames the
/// SFTP messages we issue and correlates their replies by request id.
final class NIOSSHSFTPBackend: SFTPTransportBackend, @unchecked Sendable {
    private struct Connection {
        let group: EventLoopGroup
        let channel: Channel
        let sftpChannel: Channel
        let handler: SFTPClientHandler
    }

    private let lock = NSLock()
    private var connection: Connection?
    private var isClosed = false
    private var nextRequestID: UInt32 = 0

    private static let connectTimeout: TimeAmount = .seconds(20)
    private static let operationTimeout: Duration = .seconds(30)

    func connect(
        host: String,
        port: Int,
        credential: SFTPMediaTransportCredential,
        hostKeyPolicy: SFTPHostKeyPolicy
    ) async throws {
        lock.lock()
        guard connection == nil, !isClosed else {
            lock.unlock()
            throw MediaTransportError.invalidInput(reason: "SFTP backend already connected")
        }
        lock.unlock()

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let authDelegate = SFTPUserAuthenticationDelegate(credential: credential)
        let serverAuthDelegate = SFTPHostKeyValidator(policy: hostKeyPolicy)

        do {
            let bootstrap = ClientBootstrap(group: group)
                .connectTimeout(Self.connectTimeout)
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        let handler = NIOSSHHandler(
                            role: .client(
                                .init(
                                    userAuthDelegate: authDelegate,
                                    serverAuthDelegate: serverAuthDelegate
                                )
                            ),
                            allocator: channel.allocator,
                            inboundChildChannelInitializer: nil
                        )
                        try channel.pipeline.syncOperations.addHandler(handler)
                    }
                }

            let channel = try await bootstrap.connect(host: host, port: port).get()
            let eventLoop = channel.eventLoop
            let sftpHandler = SFTPClientHandler(eventLoop: eventLoop)

            // Open the `sftp` subsystem child channel. We reference only the
            // (Sendable) event loop and the (@unchecked Sendable) handler inside
            // the escaping closures, never the non-Sendable `Channel` itself.
            let sftpChannel: Channel = try await channel.pipeline
                .handler(type: NIOSSHHandler.self)
                .flatMap { sshHandler -> EventLoopFuture<Channel> in
                    let promise = eventLoop.makePromise(of: Channel.self)
                    sshHandler.createChannel(promise, channelType: .session) { childChannel, channelType in
                        guard channelType == .session else {
                            return childChannel.eventLoop.makeFailedFuture(
                                MediaTransportError.protocolViolation(reason: "unexpected SSH channel type")
                            )
                        }
                        return childChannel.eventLoop.makeCompletedFuture {
                            try childChannel.syncOptions?.setOption(.allowRemoteHalfClosure, value: true)
                            try childChannel.pipeline.syncOperations.addHandler(sftpHandler)
                        }
                    }
                    return promise.futureResult
                }.get()

            // Wait for the `sftp` subsystem request + INIT/VERSION handshake.
            try await withThrowingTimeout(Self.operationTimeout) {
                try await sftpHandler.readyFuture.get()
            }

            lock.lock()
            if isClosed {
                lock.unlock()
                try? await sftpChannel.close().get()
                try? await channel.close().get()
                try? await group.shutdownGracefully()
                throw MediaTransportError.cancelled
            }
            connection = Connection(group: group, channel: channel, sftpChannel: sftpChannel, handler: sftpHandler)
            lock.unlock()
        } catch {
            try? await group.shutdownGracefully()
            throw mapSFTPError(error)
        }
    }

    func realPath(_ path: String) async throws -> String {
        let body = try await request { id, allocator in
            SFTP.encodeRealPath(id: id, path: path, allocator: allocator)
        }
        switch body {
        case let .name(entries):
            guard let first = entries.first else {
                throw MediaTransportError.protocolViolation(reason: "empty SFTP REALPATH response")
            }
            return first.filename
        case let .status(code, _):
            throw SFTPStatusError(code: code)
        default:
            throw MediaTransportError.protocolViolation(reason: "unexpected SFTP REALPATH response")
        }
    }

    func list(path: String) async throws -> [SFTPBackendEntry] {
        let openBody = try await request { id, allocator in
            SFTP.encodeOpenDir(id: id, path: path, allocator: allocator)
        }
        let handle: ByteBuffer
        switch openBody {
        case let .handle(buffer):
            handle = buffer
        case let .status(code, _):
            throw SFTPStatusError(code: code)
        default:
            throw MediaTransportError.protocolViolation(reason: "unexpected SFTP OPENDIR response")
        }

        var entries: [SFTPBackendEntry] = []
        defer {
            let handleCopy = handle
            Task { await self.closeRawHandle(handleCopy) }
        }
        while true {
            let readBody = try await request { id, allocator in
                SFTP.encodeReadDir(id: id, handle: handle, allocator: allocator)
            }
            switch readBody {
            case let .name(names):
                for name in names {
                    entries.append(backendEntry(name: name.filename, attributes: name.attributes))
                }
            case let .status(code, _):
                if code == .eof { return entries }
                throw SFTPStatusError(code: code)
            default:
                throw MediaTransportError.protocolViolation(reason: "unexpected SFTP READDIR response")
            }
        }
    }

    func stat(path: String) async throws -> SFTPBackendEntry {
        let body = try await request { id, allocator in
            SFTP.encodeStat(id: id, path: path, allocator: allocator)
        }
        switch body {
        case let .attrs(attributes):
            return backendEntry(name: lastComponent(of: path), attributes: attributes)
        case let .status(code, _):
            throw SFTPStatusError(code: code)
        default:
            throw MediaTransportError.protocolViolation(reason: "unexpected SFTP STAT response")
        }
    }

    func readSmallFile(path: String, maximumBytes: Int) async throws -> Data {
        let opened = try await openFile(path: path)
        do {
            guard opened.entry.kind == .file,
                  let size = opened.entry.size,
                  size <= maximumBytes else {
                throw MediaTransportError.invalidInput(reason: "small-file bound exceeded")
            }
            let data = try await read(handle: opened.handle, offset: 0, length: maximumBytes + 1)
            guard data.count <= maximumBytes else {
                throw MediaTransportError.invalidInput(reason: "small-file bound exceeded")
            }
            await closeFile(handle: opened.handle)
            return data
        } catch {
            await closeFile(handle: opened.handle)
            throw error
        }
    }

    func openFile(path: String) async throws -> (handle: SFTPFileHandle, entry: SFTPBackendEntry) {
        let openBody = try await request { id, allocator in
            SFTP.encodeOpenRead(id: id, path: path, allocator: allocator)
        }
        let rawHandle: ByteBuffer
        switch openBody {
        case let .handle(buffer):
            rawHandle = buffer
        case let .status(code, _):
            throw SFTPStatusError(code: code)
        default:
            throw MediaTransportError.protocolViolation(reason: "unexpected SFTP OPEN response")
        }

        do {
            let attrsBody = try await request { id, allocator in
                SFTP.encodeFStat(id: id, handle: rawHandle, allocator: allocator)
            }
            switch attrsBody {
            case let .attrs(attributes):
                let handle = SFTPFileHandle(rawValue: Array(rawHandle.readableBytesView))
                return (handle, backendEntry(name: lastComponent(of: path), attributes: attributes))
            case let .status(code, _):
                throw SFTPStatusError(code: code)
            default:
                throw MediaTransportError.protocolViolation(reason: "unexpected SFTP FSTAT response")
            }
        } catch {
            await closeRawHandle(rawHandle)
            throw error
        }
    }

    func read(handle: SFTPFileHandle, offset: Int64, length: Int) async throws -> Data {
        guard offset >= 0, length > 0 else {
            throw MediaTransportError.invalidInput(reason: "invalid SFTP read")
        }
        let handleBuffer = ByteBuffer(bytes: handle.rawValue)
        var result = Data()
        result.reserveCapacity(min(length, 1 << 20))
        var position = offset
        var remaining = length

        while remaining > 0 {
            let chunk = min(remaining, SFTP.maxReadChunk)
            let body = try await request { id, allocator in
                SFTP.encodeRead(
                    id: id,
                    handle: handleBuffer,
                    offset: UInt64(position),
                    length: UInt32(chunk),
                    allocator: allocator
                )
            }
            switch body {
            case let .data(buffer):
                let count = buffer.readableBytes
                guard count > 0 else { return result }
                result.append(contentsOf: buffer.readableBytesView)
                position += Int64(count)
                remaining -= count
                // A short read means we reached the end of what the server will
                // return contiguously; stop rather than spin at EOF.
                if count < chunk { return result }
            case let .status(code, _):
                if code == .eof { return result }
                throw SFTPStatusError(code: code)
            default:
                throw MediaTransportError.protocolViolation(reason: "unexpected SFTP READ response")
            }
        }
        return result
    }

    func closeFile(handle: SFTPFileHandle) async {
        await closeRawHandle(ByteBuffer(bytes: handle.rawValue))
    }

    func shutdown() async {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return
        }
        isClosed = true
        let connection = self.connection
        self.connection = nil
        lock.unlock()

        guard let connection else { return }
        connection.handler.failAll(error: MediaTransportError.cancelled)
        try? await connection.sftpChannel.close().get()
        try? await connection.channel.close().get()
        try? await connection.group.shutdownGracefully()
    }

    // MARK: - Request plumbing

    private func request(
        _ make: @escaping (UInt32, ByteBufferAllocator) -> ByteBuffer
    ) async throws -> SFTP.ResponseBody {
        let connection = try currentConnection()
        let id = nextID()
        let channel = connection.sftpChannel
        let handler = connection.handler
        let eventLoop = channel.eventLoop
        let framed = make(id, channel.allocator)
        let promise = eventLoop.makePromise(of: SFTP.ResponseBody.self)

        // Register the pending promise on the loop first, then write. Both are
        // enqueued onto the same event loop in FIFO order, so the reply can never
        // beat the registration.
        eventLoop.execute { handler.register(id: id, promise: promise) }
        channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(framed)))
            .whenFailure { error in
                eventLoop.execute { handler.failRequest(id: id, error: error) }
            }

        return try await withThrowingTimeout(Self.operationTimeout) {
            try await promise.futureResult.get()
        }
    }

    private func closeRawHandle(_ handle: ByteBuffer) async {
        guard let connection = try? currentConnection() else { return }
        let id = nextID()
        let channel = connection.sftpChannel
        let handler = connection.handler
        let eventLoop = channel.eventLoop
        let framed = SFTP.encodeClose(id: id, handle: handle, allocator: channel.allocator)
        let promise = eventLoop.makePromise(of: SFTP.ResponseBody.self)

        eventLoop.execute { handler.register(id: id, promise: promise) }
        channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(framed)))
            .whenFailure { error in
                eventLoop.execute { handler.failRequest(id: id, error: error) }
            }
        // Best-effort: we don't care about the CLOSE status, but bound the wait.
        _ = try? await withThrowingTimeout(Self.operationTimeout) {
            try await promise.futureResult.get()
        }
    }

    private func currentConnection() throws -> Connection {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed, let connection else {
            throw MediaTransportError.cancelled
        }
        return connection
    }

    private func nextID() -> UInt32 {
        lock.lock()
        defer { lock.unlock() }
        nextRequestID &+= 1
        return nextRequestID
    }

    private func backendEntry(name: String, attributes: SFTP.FileAttributes) -> SFTPBackendEntry {
        let kind = attributes.kind ?? .file
        return SFTPBackendEntry(
            name: name,
            kind: kind,
            size: kind == .directory ? nil : attributes.size,
            modifiedAt: attributes.modificationTime
        )
    }

    private func lastComponent(of path: String) -> String {
        let trimmed = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }
}

// MARK: - SFTP subsystem channel handler

/// Frames SFTP packets on the `sftp` subsystem channel and correlates each reply
/// to its request id. State is confined to the channel's event loop; the backend
/// only touches it via `eventLoop.flatSubmit`, so it is safe under strict
/// concurrency.
final class SFTPClientHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData

    private let eventLoop: EventLoop
    private let readyPromise: EventLoopPromise<Void>
    private var context: ChannelHandlerContext?
    private var inboundBuffer: ByteBuffer
    private var pending: [UInt32: EventLoopPromise<SFTP.ResponseBody>] = [:]
    private var readyResolved = false
    private var sentInit = false
    private var terminalError: Error?

    var readyFuture: EventLoopFuture<Void> { readyPromise.futureResult }

    init(eventLoop: EventLoop) {
        self.eventLoop = eventLoop
        self.readyPromise = eventLoop.makePromise(of: Void.self)
        self.inboundBuffer = ByteBuffer()
    }

    /// Registers a promise for `id`. Must run on the event loop (the backend
    /// calls it via `eventLoop.execute`).
    func register(id: UInt32, promise: EventLoopPromise<SFTP.ResponseBody>) {
        if let terminalError {
            promise.fail(terminalError)
            return
        }
        pending[id] = promise
    }

    func failRequest(id: UInt32, error: Error) {
        pending.removeValue(forKey: id)?.fail(error)
    }

    func failAll(error: Error) {
        if eventLoop.inEventLoop {
            failAll0(error: error)
        } else {
            eventLoop.execute { self.failAll0(error: error) }
        }
    }

    private func failAll0(error: Error) {
        terminalError = terminalError ?? error
        let waiting = pending
        pending.removeAll()
        for promise in waiting.values {
            promise.fail(error)
        }
        if !readyResolved {
            readyResolved = true
            readyPromise.fail(error)
        }
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        failAll0(error: MediaTransportError.cancelled)
    }

    func channelActive(context: ChannelHandlerContext) {
        // Request the `sftp` subsystem; the server replies with a channel
        // success/failure user event.
        let request = SSHChannelRequestEvent.SubsystemRequest(subsystem: "sftp", wantReply: true)
        context.triggerUserOutboundEvent(request).whenFailure { [weak self] error in
            self?.failAll0(error: error)
        }
        context.fireChannelActive()
    }

    func channelInactive(context: ChannelHandlerContext) {
        failAll0(error: MediaTransportError.timeout)
        context.fireChannelInactive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            sendInit(context: context)
        case is ChannelFailureEvent:
            failAll0(error: MediaTransportError.unsupportedCapability("SFTP subsystem"))
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    private func sendInit(context: ChannelHandlerContext) {
        guard !sentInit else { return }
        sentInit = true
        let packet = SFTP.encodeInit(allocator: context.channel.allocator)
        context.writeAndFlush(wrapOutboundData(packet, context: context)).whenFailure { [weak self] error in
            self?.failAll0(error: error)
        }
    }

    private func wrapOutboundData(_ buffer: ByteBuffer, context: ChannelHandlerContext) -> NIOAny {
        context.channel.eventLoop.preconditionInEventLoop()
        return NIOAny(SSHChannelData(type: .channel, data: .byteBuffer(buffer)))
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case .byteBuffer(var bytes) = channelData.data else {
            return
        }
        // Only stdout-equivalent channel data carries SFTP packets; ignore stderr.
        guard channelData.type == .channel else {
            return
        }
        inboundBuffer.writeBuffer(&bytes)
        drainPackets(context: context)
    }

    private func drainPackets(context: ChannelHandlerContext) {
        do {
            while let packet = try SFTP.nextPacket(from: &inboundBuffer) {
                try handlePacket(packet)
            }
            inboundBuffer.discardReadBytes()
        } catch {
            failAll0(error: error)
            context.close(promise: nil)
        }
    }

    private func handlePacket(_ packet: SFTP.RawPacket) throws {
        var payload = packet.payload
        if packet.type == SFTP.PacketType.version.rawValue {
            let version = try SFTP.parseVersion(&payload)
            guard version >= 1 else {
                throw MediaTransportError.protocolViolation(reason: "unusable SFTP version")
            }
            if !readyResolved {
                readyResolved = true
                readyPromise.succeed(())
            }
            return
        }

        guard let id: UInt32 = payload.readInteger() else {
            throw MediaTransportError.protocolViolation(reason: "SFTP response missing request id")
        }
        let body = try SFTP.parseBody(type: packet.type, payload: &payload)
        guard let promise = pending.removeValue(forKey: id) else {
            // A reply for an unknown/cancelled id: drop it.
            return
        }
        promise.succeed(body)
    }
}

// MARK: - Host key validation (the SHA-256 pin)

/// Enforces the SSH host-key trust policy. For a pinned account it compares the
/// SHA-256 of the presented host key's SSH wire blob (the standard OpenSSH
/// `SHA256:` fingerprint) to the pin, failing closed on mismatch. For the
/// capture policy it accepts any key and records the fingerprint for the caller.
final class SFTPHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let policy: SFTPHostKeyPolicy
    private let captured = NIOLockedValueBox<[UInt8]?>(nil)

    init(policy: SFTPHostKeyPolicy) {
        self.policy = policy
    }

    /// The fingerprint observed during a trust-on-first-use capture, if any.
    var capturedFingerprint: [UInt8]? { captured.withLockedValue { $0 } }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        guard let fingerprint = Self.sha256Fingerprint(of: hostKey) else {
            validationCompletePromise.fail(MediaTransportError.trust(reason: "unreadable SFTP host key"))
            return
        }
        captured.withLockedValue { $0 = fingerprint }

        switch policy {
        case let .pinned(expected):
            if constantTimeEqual(fingerprint, expected) {
                validationCompletePromise.succeed(())
            } else {
                validationCompletePromise.fail(MediaTransportError.trust(reason: "SFTP host key mismatch"))
            }
        case .captureTrustOnFirstUse:
            validationCompletePromise.succeed(())
        }
    }

    /// Computes the standard OpenSSH SHA-256 host-key fingerprint: SHA-256 over
    /// the base64-decoded SSH wire-format public key blob.
    static func sha256Fingerprint(of hostKey: NIOSSHPublicKey) -> [UInt8]? {
        let openSSH = String(openSSHPublicKey: hostKey)
        let components = openSSH.split(separator: " ", omittingEmptySubsequences: true)
        guard components.count >= 2, let blob = Data(base64Encoded: String(components[1])) else {
            return nil
        }
        return Array(SHA256.hash(data: blob))
    }
}

/// A ``NIOSSHClientUserAuthenticationDelegate`` that offers exactly one credential
/// (password or private key), once. Immutable, hence safe to capture into the
/// channel initializer under strict concurrency.
final class SFTPUserAuthenticationDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let credential: SFTPMediaTransportCredential
    private let offered = NIOLockedValueBox<Bool>(false)

    init(credential: SFTPMediaTransportCredential) {
        self.credential = credential
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        // Offer our single credential once. If the server rejects it (and asks
        // again), stop so auth fails cleanly instead of looping.
        let alreadyOffered = offered.withLockedValue { value -> Bool in
            defer { value = true }
            return value
        }
        guard !alreadyOffered else {
            nextChallengePromise.succeed(nil)
            return
        }

        switch credential {
        case let .password(username, password):
            guard availableMethods.contains(.password) else {
                nextChallengePromise.succeed(nil)
                return
            }
            let offer = NIOSSHUserAuthenticationOffer(
                username: username,
                serviceName: "",
                offer: .password(.init(password: password))
            )
            nextChallengePromise.succeed(offer)
        case .privateKey:
            // Private-key auth wire support lands with the credential/keygen
            // work (the future unified add-share UI generates and stores the
            // key); this headless transport ships password auth. Fail closed
            // rather than silently offering nothing ambiguous.
            nextChallengePromise.fail(
                MediaTransportError.unsupportedCapability("SFTP private-key authentication")
            )
        }
    }
}

// MARK: - Helpers

private func constantTimeEqual(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
    guard lhs.count == rhs.count else { return false }
    var difference: UInt8 = 0
    for index in lhs.indices {
        difference |= lhs[index] ^ rhs[index]
    }
    return difference == 0
}

/// Runs `operation`, throwing ``MediaTransportError/timeout`` if it does not
/// finish within `timeout`.
private func withThrowingTimeout<Value: Sendable>(
    _ timeout: Duration,
    _ operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    try await withThrowingTaskGroup(of: Value.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw MediaTransportError.timeout
        }
        guard let result = try await group.next() else {
            throw MediaTransportError.timeout
        }
        group.cancelAll()
        return result
    }
}
