import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Orchestrates the WebDAV/HTTP requests this module proves out — capability
/// probing, bounded directory listing, and validated ranged reads — always
/// through a ``TransportSessionRegistry``-managed ephemeral session, and
/// always preflighted through ``CredentialPreflight`` before a request is
/// built.
///
/// This is the HTTP adapter integration point: it composes the other
/// primitives in this module but is not adopted by any provider yet.
public struct WebDAVClient: Sendable {
    private let registry: TransportSessionRegistry

    public init(registry: TransportSessionRegistry) {
        self.registry = registry
    }

    /// `OPTIONS` capability probe. Returns the normalized (lower-cased-key)
    /// response headers so a caller can inspect `DAV`/`Allow` without this
    /// module hard-coding an opinion about what capabilities matter.
    public func capabilities(
        url: URL,
        sessionKey: TransportSessionKey,
        credential: WebDAVCredential,
        trustPolicy: TrustPolicy
    ) async throws -> [String: String] {
        let (_, response) = try await execute(
            requestBuilder: { WebDAVRequestBuilder.options(url: $0) },
            url: url,
            sessionKey: sessionKey,
            credential: credential,
            trustPolicy: trustPolicy,
            maxResponseBytes: 64 * 1024
        )
        try validateAuthenticationStatus(response)
        guard (200..<300).contains(response.statusCode) else {
            throw TransportError.protocolError(
                status: response.statusCode,
                detail: "expected a successful OPTIONS response"
            )
        }
        return HTTPHeaderUtilities.normalizedHeaders(from: response.allHeaderFields)
    }

    /// Bounded `PROPFIND` + parse. `path` is the already-normalized,
    /// root-relative path being listed (must be at/under `root.path`).
    public func listChildren(
        root: WebDAVRoot,
        path: String,
        depth: PropfindDepth,
        sessionKey: TransportSessionKey,
        credential: WebDAVCredential,
        trustPolicy: TrustPolicy,
        limits: PropfindParseLimits = .default
    ) async throws -> [WebDAVEntry] {
        guard WebDAVPathPolicy.isNormalizedDecodedPath(path),
              WebDAVPathPolicy.isWithinRoot(path, root: root.path) else {
            throw TransportError.pathEscapesRoot
        }
        guard let url = root.origin.url(path: path) else {
            throw TransportError.invalidOrigin(reason: "could not build URL for path \(path)")
        }

        let (data, response) = try await execute(
            requestBuilder: { WebDAVRequestBuilder.propfind(url: $0, depth: depth) },
            url: url,
            sessionKey: sessionKey,
            credential: credential,
            trustPolicy: trustPolicy,
            maxResponseBytes: limits.maxResponseBytes
        )
        try validateAuthenticationStatus(response)
        guard response.statusCode == 207 else {
            throw TransportError.protocolError(status: response.statusCode, detail: "expected 207 Multi-Status from PROPFIND")
        }
        guard let finalURL = response.url,
              TransportOrigin(url: finalURL) == root.origin,
              let finalPath = WebDAVPathPolicy.normalizedPath(of: finalURL),
              WebDAVPathPolicy.isWithinRoot(finalPath, root: root.path) else {
            throw TransportError.pathEscapesRoot
        }
        return try PropfindXMLParser.parse(
            data: data,
            root: root,
            requestPath: finalPath,
            limits: limits
        )
    }

    /// Establishes seekability for `url`: a 1-byte range probe that must
    /// come back `206` with a strong `ETag`.
    public func probeRange(
        url: URL,
        sessionKey: TransportSessionKey,
        credential: WebDAVCredential,
        trustPolicy: TrustPolicy
    ) async throws -> RangeProbeResult {
        let (data, response) = try await execute(
            requestBuilder: { RangeProbe.probeRequest(url: $0) },
            url: url,
            sessionKey: sessionKey,
            credential: credential,
            trustPolicy: trustPolicy,
            maxResponseBytes: 1
        )
        try validateAuthenticationStatus(response)
        guard let resourceURL = response.url,
              TransportOrigin(url: resourceURL) == sessionKey.origin else {
            throw TransportError.invalidOrigin(reason: "range probe response URL did not match the session origin")
        }
        let headers = HTTPHeaderUtilities.normalizedHeaders(from: response.allHeaderFields)
        switch RangeProbe.validateProbe(
            status: response.statusCode,
            headers: headers,
            bodyLength: data.count,
            resourceURL: resourceURL
        ) {
        case .success(let result):
            return result
        case .failure(let error):
            throw error
        }
    }

    /// A single validated bounded read, gated on the exact strong `ETag`
    /// `probeRange` returned. Throws ``TransportError/sourceChanged(reason:)``
    /// if the resource changed since the probe.
    public func readRange(
        url: URL,
        start: Int64,
        end: Int64,
        representation: RangeProbeResult,
        sessionKey: TransportSessionKey,
        credential: WebDAVCredential,
        trustPolicy: TrustPolicy,
        maxReadBytes: Int64 = RangeProbe.defaultMaxReadBytes
    ) async throws -> Data {
        let builtRequest: URLRequest
        guard url.absoluteString == representation.resourceURL.absoluteString else {
            throw TransportError.sourceChanged(reason: "read URL did not match the probed resource")
        }
        switch RangeProbe.readRequest(
            url: url,
            start: start,
            end: end,
            ifMatch: representation.etag,
            maxReadBytes: maxReadBytes
        ) {
        case .success(let request):
            builtRequest = request
        case .failure(let error):
            throw error
        }

        let (readSizeMinusOne, subtractOverflowed) = end.subtractingReportingOverflow(start)
        let (readSize, addOverflowed) = readSizeMinusOne.addingReportingOverflow(1)
        guard !subtractOverflowed,
              !addOverflowed,
              readSize <= Int64(Int.max) else {
            throw TransportError.rangeValidationFailed(reason: "range size cannot be represented")
        }

        let (data, response) = try await execute(
            requestBuilder: { _ in builtRequest },
            url: url,
            sessionKey: sessionKey,
            credential: credential,
            trustPolicy: trustPolicy,
            maxResponseBytes: Int(readSize)
        )
        try validateAuthenticationStatus(response)
        guard response.url?.absoluteString == representation.resourceURL.absoluteString else {
            throw TransportError.sourceChanged(reason: "read response URL did not match the probed resource")
        }
        let headers = HTTPHeaderUtilities.normalizedHeaders(from: response.allHeaderFields)
        switch RangeProbe.validateRead(
            status: response.statusCode,
            headers: headers,
            bodyLength: data.count,
            expectedStart: start,
            expectedEnd: end,
            expectedTotal: representation.totalLength,
            expectedETag: representation.etag
        ) {
        case .success:
            return data
        case .failure(let error):
            throw error
        }
    }

    /// Bounded `PROPFIND` `Depth: 0` + parse for a **single** resource
    /// (`stat`). Unlike ``listChildren(root:path:depth:…)`` this keeps the
    /// self-entry (a Depth:0 response's only entry) and returns exactly it,
    /// failing closed if the server returns no usable entry or more than one.
    public func properties(
        root: WebDAVRoot,
        path: String,
        sessionKey: TransportSessionKey,
        credential: WebDAVCredential,
        trustPolicy: TrustPolicy,
        limits: PropfindParseLimits = .default
    ) async throws -> WebDAVEntry {
        guard WebDAVPathPolicy.isNormalizedDecodedPath(path),
              WebDAVPathPolicy.isWithinRoot(path, root: root.path) else {
            throw TransportError.pathEscapesRoot
        }
        guard let url = root.origin.url(path: path) else {
            throw TransportError.invalidOrigin(reason: "could not build URL for path \(path)")
        }

        let (data, response) = try await execute(
            requestBuilder: { WebDAVRequestBuilder.propfind(url: $0, depth: .zero) },
            url: url,
            sessionKey: sessionKey,
            credential: credential,
            trustPolicy: trustPolicy,
            maxResponseBytes: limits.maxResponseBytes
        )
        try validateAuthenticationStatus(response)
        guard response.statusCode == 207 else {
            throw TransportError.protocolError(status: response.statusCode, detail: "expected 207 Multi-Status from PROPFIND")
        }
        guard let finalURL = response.url,
              TransportOrigin(url: finalURL) == root.origin,
              let finalPath = WebDAVPathPolicy.normalizedPath(of: finalURL),
              WebDAVPathPolicy.isWithinRoot(finalPath, root: root.path) else {
            throw TransportError.pathEscapesRoot
        }
        let entries = try PropfindXMLParser.parse(
            data: data,
            root: root,
            requestPath: finalPath,
            limits: limits,
            includeSelfEntry: true
        )
        // A Depth:0 PROPFIND describes exactly the queried resource. Select the
        // self-entry explicitly rather than trusting the server returned only
        // it — a misbehaving server that echoes a sibling/child (or several)
        // must not cause us to return the wrong resource's metadata.
        let selfEntries = entries.filter {
            WebDAVPathPolicy.isSelfEntry(resolvedPath: $0.resolvedPath, requestPath: finalPath)
        }
        guard selfEntries.count == 1, let entry = selfEntries.first else {
            throw TransportError.malformedMultistatus(
                reason: "Depth:0 PROPFIND did not return exactly the queried resource (\(selfEntries.count) self-entries)"
            )
        }
        return entry
    }

    /// A single unconditional bounded whole-file `GET`, capped at `maxBytes`.
    /// A body that exceeds the cap is a hard ``TransportError/responseTooLarge``
    /// (never a silent truncation), so a caller can't mistake a partial read of
    /// a large file for a complete small one. Intended for small sidecar/
    /// metadata files, not media byte-ranges (use ``readRange`` for those).
    public func getBounded(
        url: URL,
        maxBytes: Int,
        sessionKey: TransportSessionKey,
        credential: WebDAVCredential,
        trustPolicy: TrustPolicy
    ) async throws -> Data {
        guard maxBytes > 0 else {
            throw TransportError.rangeValidationFailed(reason: "bounded read cap must be positive")
        }
        let (data, response) = try await execute(
            requestBuilder: { WebDAVRequestBuilder.get(url: $0) },
            url: url,
            sessionKey: sessionKey,
            credential: credential,
            trustPolicy: trustPolicy,
            maxResponseBytes: maxBytes
        )
        try validateAuthenticationStatus(response)
        guard response.statusCode == 200 else {
            throw TransportError.protocolError(
                status: response.statusCode,
                detail: "expected 200 OK for a bounded whole-file GET"
            )
        }
        guard let resourceURL = response.url,
              TransportOrigin(url: resourceURL) == sessionKey.origin else {
            throw TransportError.invalidOrigin(reason: "bounded GET response URL did not match the session origin")
        }
        return data
    }

    // MARK: - Shared execution path

    private func execute(
        requestBuilder: (URL) -> URLRequest,
        url: URL,
        sessionKey: TransportSessionKey,
        credential: WebDAVCredential,
        trustPolicy: TrustPolicy,
        maxResponseBytes: Int
    ) async throws -> (Data, HTTPURLResponse) {
        guard let origin = TransportOrigin(url: url), origin == sessionKey.origin else {
            throw TransportError.invalidOrigin(reason: "request URL does not match the session key's origin")
        }
        // Reject any reusable credential over cleartext *before* touching
        // the network or even constructing the authenticated request.
        if let rejection = CredentialPreflight.validate(credential: credential, origin: origin) {
            throw rejection
        }

        var request = requestBuilder(url)
        if case .bearerToken(let token) = credential {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let session = try await registry.session(
            for: sessionKey,
            credential: credential,
            trustPolicy: trustPolicy
        )
        let result = try await session.data(for: request, maxResponseBytes: maxResponseBytes)
        return (result.data, result.response)
    }

    private func validateAuthenticationStatus(_ response: HTTPURLResponse) throws {
        if response.statusCode == 401 || response.statusCode == 403 {
            throw TransportError.authenticationFailed(reason: "server rejected the request")
        }
    }
}
