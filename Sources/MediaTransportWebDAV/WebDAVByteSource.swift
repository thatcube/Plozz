import CoreModels
import Foundation
import MediaTransportCore
import MediaTransportHTTP

/// A random-access byte source over WebDAV/HTTP `Range` reads.
///
/// Every read is a bounded `Range` `GET` gated on the exact strong `ETag`
/// established by the `openSource` probe (`If-Match`), so the moment the
/// remote file changes underneath playback the read fails closed with
/// `.sourceChanged` rather than silently returning bytes from a different
/// representation. Reads are stateless (no server-side cursor/handle), so —
/// unlike SMB's channel-per-cursor source — no per-cursor isolation is needed:
/// a cancelled read cancels only its own `URLSessionTask`, and the owning
/// ``WebDAVMediaTransportSession`` drains the shared ephemeral session on
/// shutdown.
final class WebDAVByteSource: MediaTransportByteSource, @unchecked Sendable {
    let byteSize: Int64

    private let client: WebDAVClient
    private let resourceURL: URL
    private let representation: RangeProbeResult
    private let sessionKey: TransportSessionKey
    private let credential: WebDAVCredential
    private let trustPolicy: TrustPolicy

    init(
        client: WebDAVClient,
        representation: RangeProbeResult,
        sessionKey: TransportSessionKey,
        credential: WebDAVCredential,
        trustPolicy: TrustPolicy
    ) {
        self.client = client
        self.resourceURL = representation.resourceURL
        self.representation = representation
        self.sessionKey = sessionKey
        self.credential = credential
        self.trustPolicy = trustPolicy
        self.byteSize = representation.totalLength
    }

    func read(at offset: Int64, length: Int) async throws -> Data {
        guard offset >= 0, length > 0 else {
            throw MediaTransportError.invalidInput(reason: "invalid WebDAV byte range")
        }
        // Reads at or past EOF are a normal end-of-stream signal (AVIO probes
        // past the end), not an error — return empty rather than asking the
        // server for an unsatisfiable range (which would be a 416).
        guard offset < byteSize else {
            return Data()
        }
        let lastByte = byteSize - 1
        let requestedEnd = offset.addingReportingOverflow(Int64(length) - 1)
        let end = requestedEnd.overflow ? lastByte : min(requestedEnd.partialValue, lastByte)

        do {
            return try await client.readRange(
                url: resourceURL,
                start: offset,
                end: end,
                representation: representation,
                sessionKey: sessionKey,
                credential: credential,
                trustPolicy: trustPolicy
            )
        } catch {
            throw mapWebDAVError(error)
        }
    }

    func shutdown() async {
        // No per-source resource to release: the ephemeral URLSession backing
        // these reads is owned by the transport session's registry and drained
        // when that session shuts down. Deterministic teardown is therefore the
        // session's responsibility; a cancelled in-flight read is torn down at
        // the URLSessionTask level by structured cancellation.
    }
}
