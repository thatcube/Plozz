import Foundation
import CoreModels
import CoreNetworking
import ProviderJellyfin

/// One-shot, cross-platform self-heal for stale server names.
///
/// Historically iOS added Jellyfin/Emby accounts with a PLACEHOLDER name
/// (`ProviderKind.displayName`, e.g. "Jellyfin") and never fetched the server's real
/// name, so those accounts — and any devices they synced to — showed "Jellyfin"
/// instead of the server's actual name. Sign-in now resolves the real name, but
/// existing accounts still carry the stale value.
///
/// This refresher re-reads each managed (MediaBrowser: Jellyfin/Emby) server's public
/// system info (no auth required) and, when the resolved name differs, rewrites the
/// stored account with the correct name via `add(_:token:)` (which upserts metadata).
/// It is:
///   • idempotent (a matching name is a no-op),
///   • non-destructive (offline/unreachable servers are skipped, tokens untouched),
///   • shared by tvOS + iOS so both platforms converge identically.
public struct ServerNameRefresher: Sendable {
    private let accountStore: AccountPersisting
    private let http: HTTPClient

    public init(accountStore: AccountPersisting, http: HTTPClient = URLSessionHTTPClient()) {
        self.accountStore = accountStore
        self.http = http
    }

    /// Refresh managed server names. Returns the number of accounts updated. Safe to
    /// call on every launch; only reachable servers whose name actually changed are
    /// rewritten.
    @discardableResult
    public func refresh() async -> Int {
        let accounts = accountStore.loadAccounts()
        let deviceID = accountStore.deviceID()
        var updated = 0

        for account in accounts where account.server.provider.usesMediaBrowserAPI {
            guard let token = accountStore.token(for: account.id) else { continue }
            let client = JellyfinClient(
                baseURL: account.server.baseURL,
                deviceProfile: JellyfinDeviceProfile(deviceID: deviceID),
                providerKind: account.server.provider,
                http: http
            )
            guard let info = try? await client.publicSystemInfo() else { continue }
            // `publicSystemInfo` already applies the canonical ServerName ?? host ??
            // "<Provider> Server" fallback, so a non-placeholder here is authoritative.
            guard !info.name.isEmpty, info.name != account.server.name else { continue }

            var server = account.server
            server.name = info.name
            if server.version == nil { server.version = info.version }
            var refreshed = account
            refreshed.server = server
            do {
                try accountStore.add(refreshed, token: token)
                updated += 1
                PlozzLog.auth.info("ServerNameRefresher: \(account.server.name) → \(info.name)")
            } catch {
                PlozzLog.auth.error("ServerNameRefresher: failed to update \(account.id): \(error.localizedDescription)")
            }
        }
        return updated
    }
}
