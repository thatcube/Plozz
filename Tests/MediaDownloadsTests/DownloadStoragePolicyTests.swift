import CoreModels
import XCTest
@testable import MediaDownloads

final class DownloadStoragePolicyTests: XCTestCase {

    func testIOSPolicyUsesBackupExcludedPersistentDirectory() throws {
        let sub = "PlozzDownloadsTest-\(UUID().uuidString)"
        let locator = PlatformDownloadStorageLocator(
            platform: .backupExcludedPersistent, subdirectory: sub
        )
        let dir = try locator.pinnedMediaDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
        // Under Application Support or Documents (never Caches).
        XCTAssertFalse(dir.path.contains("/Caches/"))
        let values = try dir.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    func testTVOSPolicyUsesCachesDirectory() throws {
        let sub = "PlozzDownloadsTest-\(UUID().uuidString)"
        let locator = PlatformDownloadStorageLocator(platform: .caches, subdirectory: sub)
        let dir = try locator.pinnedMediaDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
        XCTAssertTrue(dir.path.contains("/Caches/"))
        // tvOS does not mark Caches excluded-from-backup.
        let values = try dir.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertNotEqual(values.isExcludedFromBackup, true)
    }

    func testPinnedFileURLComposition() throws {
        let sub = "PlozzDownloadsTest-\(UUID().uuidString)"
        let locator = PlatformDownloadStorageLocator(platform: .caches, subdirectory: sub)
        let record = try DownloadTestFactory.record(localFileName: "media.mkv")
        defer { try? FileManager.default.removeItem(at: try locator.pinnedMediaDirectory()) }

        let url = try locator.pinnedFileURL(for: record)
        XCTAssertEqual(url.lastPathComponent, "media.mkv")
        XCTAssertEqual(
            url.deletingLastPathComponent().lastPathComponent,
            MediaIdentityKey.folderName(forKey: record.identityKey)
        )
    }
}
