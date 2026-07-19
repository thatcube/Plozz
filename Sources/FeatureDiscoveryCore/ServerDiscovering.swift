import Foundation
import CoreModels

/// Discovers Jellyfin servers on the local network.
///
/// Declared in its own (portable) file so view-models can depend on the
/// abstraction without importing the `Network`-based implementation.
public protocol ServerDiscovering: Sendable {
    /// Streams unique `MediaServer`s as they answer, stopping after `timeout`.
    func discover(timeout: TimeInterval) -> AsyncStream<MediaServer>
}
