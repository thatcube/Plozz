import CoreModels
import Foundation

/// Bridges the download registry to the playback layer's ``OfflinePlaybackResolving``
/// seam: answers "play this from disk?" for a `MediaItem`, returning the pinned
/// `file://` URL only for a **completed** download whose file still exists.
public struct RegistryOfflinePlaybackResolver:
    OfflinePlaybackResolving,
    @unchecked Sendable
{
    private let registry: DownloadedMediaRegistry
    private let storage: any DownloadStorageLocating
    private let fileManager: FileManager

    public init(
        registry: DownloadedMediaRegistry,
        storage: any DownloadStorageLocating,
        fileManager: FileManager = .default
    ) {
        self.registry = registry
        self.storage = storage
        self.fileManager = fileManager
    }

    public func localPlaybackURL(for item: MediaItem) async -> URL? {
        guard let record = await registry.record(for: item),
              record.status == .completed,
              let url = try? storage.pinnedFileURL(for: record),
              fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        return url
    }
}
