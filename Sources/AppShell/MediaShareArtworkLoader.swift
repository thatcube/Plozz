import CoreModels
import Foundation
import MediaTransportCore
import ProviderShare

/// Credential-safe AppShell adapter from CoreModels' artwork boundary to the
/// existing direct-file resolver. It is deliberately display-time only: no path,
/// URL, or credential leaves this type.
struct MediaShareArtworkLoader: ArtworkNetworkFileLoading {
    let resolver: any MediaTransportNetworkFileResolving

    func loadArtwork(
        _ reference: NetworkArtworkReference,
        maximumBytes: Int
    ) async throws -> Data {
        try Task.checkCancellation()
        let resolved = try await resolver.resolve(try reference.networkFileLocator())
        guard let cursor = resolved.sourceLease.makeCursor() else {
            await resolved.waitForFinalShutdown()
            throw ArtworkNetworkFileLoadError(.unavailable)
        }
        defer {
            cursor.close()
            Task.detached(priority: .utility) {
                await resolved.waitForFinalShutdown()
            }
        }

        let size = cursor.byteSize
        guard size > 0 else { return Data() }
        guard size <= Int64(maximumBytes) else {
            throw ArtworkNetworkFileLoadError(.tooLarge)
        }
        var result = Data()
        result.reserveCapacity(Int(size))
        var offset: Int64 = 0
        while offset < size {
            try Task.checkCancellation()
            let length = min(256 * 1024, Int(size - offset))
            let chunk = try await cursor.read(at: offset, length: length)
            guard !chunk.isEmpty else { break }
            result.append(chunk)
            guard result.count <= maximumBytes else { throw ArtworkNetworkFileLoadError(.tooLarge) }
            offset += Int64(chunk.count)
        }
        return result
    }
}

struct MediaShareArtworkFailureReporter: ArtworkNetworkFileFailureReporting {
    let coordinator: ShareCatalogCoordinator

    func reportArtworkFailure(
        _ failure: ArtworkNetworkFileFailure,
        for reference: NetworkArtworkReference
    ) async {
        switch failure {
        case .empty, .tooLarge, .malformed, .unsupported, .unsafeDimensions:
            await coordinator.rejectArtwork(accountKey: reference.accountID, reference: reference)
        case .unavailable, .cancelled:
            break
        }
    }
}
