import Foundation

/// Process-wide playback activity count used only to let low-priority background
/// work yield while video is on screen.
public enum PlaybackActivity {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var activeCount = 0

    public static func started() {
        lock.lock()
        activeCount += 1
        lock.unlock()
    }

    public static func finished() {
        lock.lock()
        activeCount = max(0, activeCount - 1)
        lock.unlock()
    }

    public static var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeCount > 0
    }
}
