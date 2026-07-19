#if canImport(Network)
import Foundation
import Network

/// Real network observer backed by `NWPathMonitor`. Tracks the latest path so the
/// download queue can honor Wi‑Fi‑only / pause-on-cellular / Low-Data policy.
public final class NWPathDownloadNetworkObserver: DownloadNetworkObserving, @unchecked Sendable {
    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "com.plozz.downloads.pathmonitor")
    private let lock = NSLock()
    private var latest: DownloadNetworkConditions = .unknownSatisfied

    public init() {
        self.monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let conditions = DownloadNetworkConditions(
                isSatisfied: path.status == .satisfied,
                isExpensive: path.isExpensive,
                isConstrained: path.isConstrained
            )
            self.lock.lock()
            self.latest = conditions
            self.lock.unlock()
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }

    public func currentConditions() async -> DownloadNetworkConditions {
        snapshot()
    }

    private func snapshot() -> DownloadNetworkConditions {
        lock.lock(); defer { lock.unlock() }
        return latest
    }
}
#endif
