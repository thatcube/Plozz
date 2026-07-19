import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreModels
import MediaTransportCore

struct PendingLocalArtworkFile: Sendable, Equatable {
    let relPath: String
    let size: Int64
    let modifiedAt: Date
    let stableFileID: String?
    let strongETag: String?
    let changeToken: String?
    let fingerprint: String
    let attempts: Int
}

enum ShareArtworkHeaderInspection: Sendable, Equatable {
    case validated(width: Int, height: Int, contentType: String)
    case empty
    case unsupported
    case malformed
    case incomplete
    case tooLarge
}

enum ShareArtworkHeaderInspector {
    static let maximumEdge = 16_384
    static let maximumPixels = 64_000_000

    static func inspect(_ data: Data, sourceIsComplete: Bool) -> ShareArtworkHeaderInspection {
        guard !data.isEmpty else { return .empty }
        if let dimensions = pngDimensions(data) {
            return validate(
                width: dimensions.width,
                height: dimensions.height,
                contentType: "image/png"
            )
        }
        let incremental = CGImageSourceCreateIncremental(nil)
        CGImageSourceUpdateData(incremental, data as CFData, sourceIsComplete)
        guard let type = CGImageSourceGetType(incremental) as String? else {
            return hasSupportedPrefix(data) && !sourceIsComplete ? .incomplete : .malformed
        }
        guard acceptedTypes[type] != nil else { return .unsupported }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(incremental, 0, nil) as? NSDictionary,
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else {
            return sourceIsComplete ? .malformed : .incomplete
        }
        return validate(width: width, height: height, contentType: acceptedTypes[type]!)
    }

    private static func validate(
        width: Int,
        height: Int,
        contentType: String
    ) -> ShareArtworkHeaderInspection {
        guard width <= maximumEdge, height <= maximumEdge,
              Int64(width) * Int64(height) <= Int64(maximumPixels) else {
            return .tooLarge
        }
        return .validated(width: width, height: height, contentType: contentType)
    }

    private static let acceptedTypes: [String: String] = [
        UTType.jpeg.identifier: "image/jpeg",
        UTType.png.identifier: "image/png",
        UTType.webP.identifier: "image/webp",
    ]

    private static func hasSupportedPrefix(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(12))
        let jpeg: [UInt8] = [0xFF, 0xD8, 0xFF]
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        if !bytes.isEmpty, jpeg.starts(with: bytes) || bytes.starts(with: jpeg) { return true }
        if !bytes.isEmpty, png.starts(with: bytes) || bytes.starts(with: png) { return true }
        return bytes.count >= 12
            && Array(bytes[0..<4]) == [0x52, 0x49, 0x46, 0x46]
            && Array(bytes[8..<12]) == [0x57, 0x45, 0x42, 0x50]
    }

    private static func pngDimensions(_ data: Data) -> (width: Int, height: Int)? {
        let bytes = [UInt8](data.prefix(24))
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard bytes.count >= 24,
              Array(bytes[0..<8]) == signature,
              Array(bytes[12..<16]) == Array("IHDR".utf8) else { return nil }
        func value(at offset: Int) -> Int {
            bytes[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
        }
        let width = value(at: 16)
        let height = value(at: 20)
        guard width > 0, height > 0 else { return nil }
        return (width, height)
    }
}

/// Scheduler-only, bounded header inspection for local artwork. It shares the
/// metadata browser with NFO processing, so it never creates a second admission
/// lane or competes with browsing/scanning sessions.
actor ShareLocalArtworkProbeWorker {
    static let version = 1
    static let maximumSourceBytes: Int64 = 32 * 1_024 * 1_024
    static let prefixBytes = 256 * 1_024

    private let store: ShareCatalogStore
    private let browser: ShareTransportBrowser
    private let accountID: String
    private let credentialRevision: CredentialRevision
    private var isRunning = false

    init(
        store: ShareCatalogStore,
        browser: ShareTransportBrowser,
        accountID: String,
        credentialRevision: CredentialRevision
    ) {
        self.store = store
        self.browser = browser
        self.accountID = accountID
        self.credentialRevision = credentialRevision
    }

    func close() async {
        await browser.close()
    }

    func resolvePendingSlice(
        maxItems: Int,
        maxDuration: Duration
    ) async -> ShareEnrichmentSliceResult {
        guard !isRunning else { return .init(attempted: 0, hasMore: true) }
        isRunning = true
        defer { isRunning = false }
        let limit = max(1, maxItems)
        let pending = await store.pendingArtworkProbes(limit: limit)
        guard !pending.isEmpty else { return .init(attempted: 0, hasMore: false) }

        let clock = ContinuousClock()
        let start = clock.now
        var attempted = 0
        var sawTransientFailure = false
        for file in pending {
            if Task.isCancelled { break }
            let outcome = await process(file)
            if outcome == .cancelled { break }
            if outcome == .transient { sawTransientFailure = true }
            attempted += 1
            if start.duration(to: clock.now) >= maxDuration { break }
        }
        return .init(
            attempted: attempted,
            hasMore: sawTransientFailure || Task.isCancelled || attempted < pending.count || pending.count == limit,
            retryAfter: sawTransientFailure ? .seconds(5) : nil
        )
    }

    private enum Outcome { case settled, transient, cancelled }

    private func process(_ file: PendingLocalArtworkFile) async -> Outcome {
        if Task.isCancelled { return .cancelled }
        if file.size > Self.maximumSourceBytes {
            await store.setArtworkProbeResult(file, result: .tooLarge)
            return .settled
        }
        guard let locator = makeLocator(file) else {
            await store.setArtworkProbeResult(file, result: .malformed)
            return .settled
        }
        let prefix: Data
        do {
            prefix = try await browser.readSourcePrefix(locator, maximumBytes: Self.prefixBytes)
        } catch {
            if error is CancellationError || (error as? MediaTransportError) == .cancelled || Task.isCancelled {
                return .cancelled
            }
            await store.recordArtworkProbeTransientFailure(file)
            return .transient
        }
        if Task.isCancelled { return .cancelled }
        await store.setArtworkProbeResult(
            file,
            result: ShareArtworkHeaderInspector.inspect(
                prefix,
                sourceIsComplete: file.size <= Int64(Self.prefixBytes)
            )
        )
        return .settled
    }

    private func makeLocator(_ file: PendingLocalArtworkFile) -> NetworkFileLocator? {
        let identity: RemoteFileIdentity?
        if let etag = file.strongETag {
            identity = try? .init(kind: .strongETag, value: etag)
        } else if let fileID = file.stableFileID {
            identity = try? .init(kind: .fileIdentifier, value: fileID)
        } else {
            identity = try? .init(kind: .modificationTime, modifiedAt: file.modifiedAt)
        }
        guard let identity,
              let representation = try? RemoteFileRepresentation(
                size: file.size, identity: identity, consistency: .changeDetecting
              ) else { return nil }
        return try? NetworkFileLocator(
            accountID: accountID,
            sourceID: accountID,
            credentialRevision: credentialRevision,
            relativePath: file.relPath,
            representation: representation,
            formatHint: .init(container: (file.relPath as NSString).pathExtension)
        )
    }
}
