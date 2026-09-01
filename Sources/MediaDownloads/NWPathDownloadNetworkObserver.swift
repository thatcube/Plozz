#if canImport(Network)
import Foundation
import Network

/// Real network observer backed by `NWPathMonitor`. Tracks the latest path so the
/// download queue can honor Wi‑Fi‑only / pause-on-cellular / Low-Data policy.
public final class NWPathDownloadNetworkObserver: DownloadNetworkObserving, @unchecked Sendable {
    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "com.plozz.downloads.pathmonitor")
    private let lock = NSLock()
    private var latest: DownloadNetworkConditions = .unsatisfied
    private var continuations: [
        UUID: AsyncStream<DownloadNetworkConditions>.Continuation
    ] = [:]

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
            let continuations = Array(self.continuations.values)
            self.lock.unlock()
            for continuation in continuations {
                continuation.yield(conditions)
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }

    public func currentConditions() async -> DownloadNetworkConditions {
        snapshot()
    }

    public func updates() -> AsyncStream<DownloadNetworkConditions> {
        let id = UUID()
        return AsyncStream { continuation in
            lock.lock()
            continuations[id] = continuation
            let latest = self.latest
            lock.unlock()
            continuation.yield(latest)
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuations[id] = nil
                self.lock.unlock()
            }
        }
    }

    private func snapshot() -> DownloadNetworkConditions {
        lock.lock(); defer { lock.unlock() }
        return latest
    }
}
#endif
