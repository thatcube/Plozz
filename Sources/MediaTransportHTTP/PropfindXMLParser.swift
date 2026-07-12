import Foundation

/// Bounded, namespace-tolerant `PROPFIND` multistatus parser, built on
/// Foundation's `XMLParser` (a streaming SAX-style parser — never loads a
/// DOM tree, so memory use tracks response size, not a multiplied parse
/// tree).
///
/// Namespace tolerance: real-world WebDAV servers vary wildly in how they
/// declare the `DAV:` namespace (`D:`, `d:`, `lp1:`, a bare default
/// namespace, or occasionally a missing/wrong declaration entirely). Rather
/// than trust prefixes, this parser enables `XMLParser.shouldProcessNamespaces`
/// and matches on the case-insensitive **local** element name only
/// (`href`, `response`, `propstat`, `resourcetype`, `collection`,
/// `getcontentlength`, `getlastmodified`, `getetag`, `getcontenttype`,
/// `status`), ignoring which namespace URI (if any) it resolved to.
///
/// Security posture:
///  - external entity resolution is explicitly refused
///    (`parser(_:resolveExternalEntityName:systemID:)` always returns `nil`,
///    on top of `shouldResolveExternalEntities = false`) — this parser never
///    fetches anything a document references;
///  - every href is run through ``WebDAVPathPolicy`` before being trusted;
///    malformed, cross-origin, or traversal hrefs fail the listing;
///  - the collection's own "self" entry (the href matching the queried
///    `requestPath`) is removed from the returned entries — callers get
///    children only;
///  - the response is fully bounded: a byte-size cap and an entry-count cap
///    are both hard failures, never a silent truncation.
public enum PropfindXMLParser {
    /// Parses an in-memory multistatus response.
    public static func parse(
        data: Data,
        root: WebDAVRoot,
        requestPath: String,
        limits: PropfindParseLimits = .default
    ) throws -> [WebDAVEntry] {
        guard data.count <= limits.maxResponseBytes else {
            throw TransportError.responseTooLarge(limitBytes: limits.maxResponseBytes)
        }
        return try runParser(data: data, root: root, requestPath: requestPath, limits: limits)
    }

    /// Parses a multistatus response from a stream (e.g. a large response
    /// body backed by a file, or a live download) without requiring the
    /// caller to have already materialized the whole body as `Data`.
    ///
    /// The wrapper stops the parser as soon as the byte limit is crossed, so
    /// this path remains constant-memory apart from the entries themselves.
    public static func parse(
        stream: InputStream,
        root: WebDAVRoot,
        requestPath: String,
        limits: PropfindParseLimits = .default
    ) throws -> [WebDAVEntry] {
        let bounded = BoundedInputStream(stream: stream, limit: limits.maxResponseBytes)
        let parser = XMLParser(stream: bounded)
        return try runParser(
            parser: parser,
            boundedStream: bounded,
            root: root,
            requestPath: requestPath,
            limits: limits
        )
    }

    private static func runParser(
        data: Data,
        root: WebDAVRoot,
        requestPath: String,
        limits: PropfindParseLimits
    ) throws -> [WebDAVEntry] {
        let parser = XMLParser(data: data)
        return try runParser(
            parser: parser,
            boundedStream: nil,
            root: root,
            requestPath: requestPath,
            limits: limits
        )
    }

    private static func runParser(
        parser: XMLParser,
        boundedStream: BoundedInputStream?,
        root: WebDAVRoot,
        requestPath: String,
        limits: PropfindParseLimits
    ) throws -> [WebDAVEntry] {
        let delegate = MultistatusParserDelegate(root: root, requestPath: requestPath, maxEntries: limits.maxEntries)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false

        let succeeded = parser.parse()
        if boundedStream?.exceededLimit == true {
            throw TransportError.responseTooLarge(limitBytes: limits.maxResponseBytes)
        }
        if let limitError = delegate.limitError {
            throw limitError
        }
        if let policyError = delegate.policyError {
            throw policyError
        }
        if let documentError = delegate.documentError {
            throw documentError
        }
        guard succeeded else {
            let reason = parser.parserError?.localizedDescription ?? delegate.firstParseErrorDescription ?? "unknown XML parse failure"
            throw TransportError.malformedMultistatus(reason: reason)
        }
        return delegate.entries
    }
}

private final class BoundedInputStream: InputStream {
    private let stream: InputStream
    private let limit: Int
    private var bytesRead = 0
    private(set) var exceededLimit = false

    init(stream: InputStream, limit: Int) {
        self.stream = stream
        self.limit = max(0, limit)
        super.init(data: Data())
    }

    override func open() {
        stream.open()
    }

    override func close() {
        stream.close()
    }

    override var streamStatus: Stream.Status {
        stream.streamStatus
    }

    override var streamError: Error? {
        stream.streamError
    }

    override var hasBytesAvailable: Bool {
        stream.hasBytesAvailable
    }

    override func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength len: Int) -> Int {
        let remaining = max(0, limit - bytesRead)
        let readLimit = remaining == Int.max ? len : min(len, remaining + 1)
        guard readLimit > 0 else {
            exceededLimit = true
            return -1
        }

        let count = stream.read(buffer, maxLength: readLimit)
        if count > 0 {
            bytesRead += count
            if bytesRead > limit {
                exceededLimit = true
                return -1
            }
        }
        return count
    }
}

/// SAX-style delegate accumulating `WebDAVEntry` values from a multistatus
/// document. Not `Sendable`/thread-shared — a fresh instance is created per
/// parse and only ever touched from the (synchronous) `XMLParser.parse()`
/// call on the calling thread.
private final class MultistatusParserDelegate: NSObject, XMLParserDelegate {
    private let root: WebDAVRoot
    private let requestPath: String
    private let maxEntries: Int

    private(set) var entries: [WebDAVEntry] = []
    private(set) var limitError: TransportError?
    private(set) var policyError: TransportError?
    private(set) var documentError: TransportError?
    private(set) var firstParseErrorDescription: String?

    // Per-<response> accumulation state (committed only from a successful
    // <propstat>).
    private var elementStack: [String] = []
    private var textBuffer: String = ""
    private var currentHref: String?
    private var currentIsCollection = false
    private var currentContentLength: Int64?
    private var currentLastModified: Date?
    private var currentETag: ETag?
    private var currentContentType: String?
    private var currentResponseStatusIsSuccess: Bool?

    // Per-<propstat> staging state. RFC 4918 orders `<prop>` *before*
    // `<status>` inside a `<propstat>`, so a property's value is known
    // before its propstat's status is. Properties are staged here as
    // they're parsed and only merged into the `current*` (response-level)
    // fields once `</propstat>` closes and the status is known to be 2xx —
    // never committed speculatively during `<prop>` parsing itself.
    private var pendingIsCollection = false
    private var pendingContentLength: Int64?
    private var pendingLastModified: Date?
    private var pendingETag: ETag?
    private var pendingContentType: String?
    private var pendingPropstatStatusIsSuccess = false

    init(root: WebDAVRoot, requestPath: String, maxEntries: Int) {
        self.root = root
        self.requestPath = requestPath
        self.maxEntries = maxEntries
    }

    // MARK: XMLParserDelegate

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let local = elementName.lowercased()
        if elementStack.isEmpty, local != "multistatus" {
            documentError = .malformedMultistatus(reason: "root element is not multistatus")
            parser.abortParsing()
            return
        }
        elementStack.append(local)
        textBuffer = ""

        switch local {
        case "response":
            resetResponseState()
        case "propstat":
            resetPendingPropstatState()
        case "collection":
            // Only meaningful inside <resourcetype>; a bare <collection>
            // elsewhere (unlikely, but be tolerant) is ignored by context.
            if elementStack.dropLast().last == "resourcetype" {
                pendingIsCollection = true
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        textBuffer += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let local = elementName.lowercased()
        let text = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        textBuffer = ""

        switch local {
        case "href":
            if elementStack.dropLast().last == "response" {
                currentHref = text
            }
        case "status":
            // "HTTP/1.1 200 OK" — only a 2xx propstat's properties are
            // trusted; a 404 propstat (common for "prop not found" filler
            // some servers emit) must not poison the entry with absent
            // data. Per RFC 4918, <prop> precedes <status> inside a
            // <propstat>, so this fires *after* the properties below have
            // already been staged into `pending*` — the actual commit into
            // `current*` happens at </propstat>, gated on this flag.
            let parent = elementStack.dropLast().last
            if parent == "propstat" {
                pendingPropstatStatusIsSuccess = Self.statusLineIsSuccess(text)
            } else if parent == "response" {
                currentResponseStatusIsSuccess = Self.statusLineIsSuccess(text)
            }
        case "getcontentlength":
            if let length = Int64(text), length >= 0 {
                pendingContentLength = length
            } else {
                pendingContentLength = nil
            }
        case "getlastmodified":
            pendingLastModified = Self.parseHTTPDate(text)
        case "getetag":
            pendingETag = ETag(headerValue: text)
        case "getcontenttype":
            pendingContentType = text.isEmpty ? nil : text
        case "propstat":
            commitPendingPropstatIfSuccessful()
        case "response":
            finishCurrentResponse(parser: parser)
        default:
            break
        }

        if !elementStack.isEmpty { elementStack.removeLast() }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        if firstParseErrorDescription == nil {
            firstParseErrorDescription = parseError.localizedDescription
        }
    }

    /// Never resolve external entities — refusing here is defense-in-depth
    /// on top of `shouldResolveExternalEntities = false`.
    func parser(
        _ parser: XMLParser,
        resolveExternalEntityName name: String,
        systemID: String?
    ) -> Data? {
        nil
    }

    // MARK: - Helpers

    private func resetResponseState() {
        currentHref = nil
        currentIsCollection = false
        currentContentLength = nil
        currentLastModified = nil
        currentETag = nil
        currentContentType = nil
        currentResponseStatusIsSuccess = nil
        resetPendingPropstatState()
    }

    private func resetPendingPropstatState() {
        pendingIsCollection = false
        pendingContentLength = nil
        pendingLastModified = nil
        pendingETag = nil
        pendingContentType = nil
        pendingPropstatStatusIsSuccess = false
    }

    /// Merges the just-finished `<propstat>`'s staged properties into the
    /// response-level `current*` fields, but only if its `<status>` was
    /// 2xx. A later 404 propstat (or one with no properties at all) never
    /// overwrites values a prior successful propstat already committed —
    /// multiple `<propstat>` blocks per `<response>` are normal (WebDAV
    /// servers commonly split "found" and "not found" properties across
    /// separate propstats).
    private func commitPendingPropstatIfSuccessful() {
        defer { resetPendingPropstatState() }
        guard pendingPropstatStatusIsSuccess else { return }

        if pendingIsCollection { currentIsCollection = true }
        if let pendingContentLength { currentContentLength = pendingContentLength }
        if let pendingLastModified { currentLastModified = pendingLastModified }
        if let pendingETag { currentETag = pendingETag }
        if let pendingContentType { currentContentType = pendingContentType }
    }

    private func finishCurrentResponse(parser: XMLParser) {
        defer { resetResponseState() }

        guard let href = currentHref, !href.isEmpty else { return }
        guard currentResponseStatusIsSuccess != false else { return }
        let resolvedPath: String
        do {
            resolvedPath = try WebDAVPathPolicy.resolve(href: href, root: root, requestPath: requestPath)
        } catch let error as TransportError {
            policyError = error
            parser.abortParsing()
            return
        } catch {
            policyError = .pathEscapesRoot
            parser.abortParsing()
            return
        }

        // Drop the collection's own "self" entry (the queried collection,
        // echoed back alongside its children in a Depth:1 response).
        if WebDAVPathPolicy.isSelfEntry(resolvedPath: resolvedPath, requestPath: requestPath) {
            return
        }

        let entry = WebDAVEntry(
            resolvedPath: resolvedPath,
            isCollection: currentIsCollection,
            contentLength: currentContentLength,
            lastModified: currentLastModified,
            etag: currentETag,
            contentType: currentContentType
        )
        entries.append(entry)

        if entries.count > maxEntries {
            limitError = .tooManyEntries(limit: maxEntries)
            parser.abortParsing()
        }
    }

    private static func statusLineIsSuccess(_ statusLine: String) -> Bool {
        // Format: "HTTP/1.1 200 OK". Tolerate any HTTP version token.
        let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2, let code = Int(parts[1]) else { return false }
        return (200..<300).contains(code)
    }

    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    private static func parseHTTPDate(_ value: String) -> Date? {
        httpDateFormatter.date(from: value)
    }
}
