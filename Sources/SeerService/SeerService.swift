import Foundation
import Observation
import CoreModels
import CoreNetworking

/// The state of the device's connection to a Seerr (Overseerr / Jellyseerr)
/// instance, rendered by Settings.
public enum SeerConnectionPhase: Equatable, Sendable {
    /// Status not yet determined (initial).
    case unknown
    /// No server URL / API key saved — show the entry fields.
    case unconfigured
    /// A connect/test attempt is in flight.
    case connecting
    /// Connected; `summary` is a short label (server version) for the UI.
    case connected(summary: String)
    /// A connect/test attempt failed; the message is user-facing.
    case failed(String)
}

/// App-level façade for the Seerr integration — the concrete backing for the
/// Home hero's `FeaturedContentProviding` seam plus the Settings connect flow.
///
/// Owns the connection lifecycle (save/test/disconnect + per-profile scoping) and
/// exposes the read paths the app uses: ``trending(limit:)`` for featured hero
/// content, ``search(_:)``, and one-tap ``request(_:)``. Provider-agnostic
/// `MediaItem`s come out, so nothing above this layer imports Seerr types.
///
/// Mirrors `TraktService`'s shape (observable phase, `setActiveProfile`,
/// `refreshStatus`, factory) so it slots into the existing Settings + AppState
/// wiring with no new patterns.
@MainActor
@Observable
public final class SeerService {
    public private(set) var phase: SeerConnectionPhase = .unknown

    @ObservationIgnored private var config: SeerConfig
    /// The shared **household** connection store (URL + admin key), backed in
    /// production by the user-independent Keychain so every tvOS system user and
    /// every profile requests against the same server. The acting Seerr user is
    /// NOT stored here — it's passed per request from the active profile.
    @ObservationIgnored private let connectionStore: SeerConnectionStoring
    /// Legacy per-profile credential store, used ONLY to migrate an existing
    /// per-profile connection into the household slot on first launch. `nil` in
    /// contexts with nothing to migrate (tests/previews).
    @ObservationIgnored private let legacyCredentialStore: SeerCredentialStoring?
    @ObservationIgnored private let http: HTTPClient

    /// Cached default Radarr/Sonarr servers, used ONLY by the admin (unmapped)
    /// request path to seed `serverId`/`profileId`/`rootFolder` (a mapped user
    /// lets Overseerr apply their own defaults). The double optional distinguishes
    /// "not fetched" (`nil`) from "fetched, none found" (`.some(nil)`).
    @ObservationIgnored private var cachedRadarr: SeerServiceServer??
    @ObservationIgnored private var cachedSonarr: SeerServiceServer??

    public init(
        connectionStore: SeerConnectionStoring,
        legacyCredentialStore: SeerCredentialStoring? = nil,
        http: HTTPClient = URLSessionHTTPClient()
    ) {
        self.connectionStore = connectionStore
        self.legacyCredentialStore = legacyCredentialStore
        self.http = http
        self.config = Self.loadConfig(from: connectionStore)
    }

    /// Whether a server URL + API key are saved (feature is set up). The hero
    /// gates its featured Request affordances on this: since featured content is
    /// only fetched (via `trending`) when a server is configured and reachable,
    /// this is the reliable, immediately-correct-at-launch signal for "there is a
    /// Seerr to request from" — and it flips to hide Request if the user
    /// disconnects Seerr while stale featured items are still on screen.
    public var isConfigured: Bool { config.isConfigured }

    /// The saved server URL, for pre-filling the Settings field on re-entry.
    public var savedBaseURLString: String? { config.baseURL?.absoluteString }

    private var client: SeerClient { SeerClient(config: config, http: http) }

    private static func loadConfig(from store: SeerConnectionStoring) -> SeerConfig {
        guard let connection = store.load() else { return SeerConfig() }
        // Acting user is per-request now, never baked into the connection config.
        return SeerConfig(baseURL: connection.baseURL, apiKey: connection.apiKey, userId: nil)
    }

    // MARK: - Lifecycle

    /// Called when the active household profile changes. The Seerr **connection**
    /// is household-wide (one shared slot), so switching profiles does NOT reload
    /// or re-namespace it — only the acting user changes, and that is read
    /// per-request from the active profile. This just re-probes reachability so
    /// the Settings row / hero gating stay fresh.
    public func setActiveProfile(namespace: String?) async {
        await refreshStatus()
    }

    /// One-time migration of a legacy per-profile Seerr connection into the shared
    /// household slot. Pass `[nil] + household profile ids` (nil = default/primary
    /// profile). Promotes the first configured connection found; no-op once the
    /// household slot is set. Reloads config + status after a promotion so the app
    /// reflects the now-shared connection immediately.
    @discardableResult
    public func migrateLegacyConnectionIfNeeded(namespaces: [String?]) async -> SeerConnectionMigrationResult {
        guard let legacyCredentialStore else {
            return SeerConnectionMigrationResult(connection: connectionStore.load(), didPromote: false)
        }
        let result = SeerConnectionMigration.migrateIfNeeded(
            into: connectionStore,
            legacy: legacyCredentialStore,
            namespaces: namespaces
        )
        if result.didPromote {
            config = Self.loadConfig(from: connectionStore)
            await refreshStatus()
        }
        return result
    }

    /// Resolves the current status: probes `/api/v1/status` when a connection is
    /// saved (so the Settings row reflects reachability). Safe to call repeatedly.
    public func refreshStatus() async {
        guard config.isConfigured else { phase = .unconfigured; return }
        await probe()
    }

    /// Validates + saves the household connection ("Connect / Test"). Probes the
    /// server first and only persists when it responds; a bad URL/key surfaces as
    /// `.failed` and nothing is stored. (`userId` is ignored — acting user is
    /// per-profile now; the parameter is kept for source compatibility.)
    public func connect(baseURL: URL, apiKey: String, userId: Int? = nil) async {
        let trial = SeerConfig(baseURL: baseURL, apiKey: apiKey, userId: nil)
        guard trial.isConfigured else {
            phase = .failed("Enter both a server address and an API key.")
            return
        }
        phase = .connecting
        do {
            let status = try await SeerClient(config: trial, http: http).status()
            // Reachable — persist to the shared household slot and adopt.
            let connection = SeerConnection(baseURL: baseURL, apiKey: trial.apiKey ?? apiKey)
            try? connectionStore.save(connection)
            config = trial
            cachedRadarr = nil
            cachedSonarr = nil
            phase = .connected(summary: Self.summary(from: status))
        } catch {
            phase = .failed(Self.message(for: error))
        }
    }

    /// Disconnects: clears the shared household connection and resets to
    /// unconfigured (for the whole household).
    public func disconnect() {
        try? connectionStore.clear()
        config = SeerConfig()
        cachedRadarr = nil
        cachedSonarr = nil
        phase = .unconfigured
    }

    private func probe() async {
        phase = .connecting
        do {
            let status = try await client.status()
            phase = .connected(summary: Self.summary(from: status))
        } catch {
            phase = .failed(Self.message(for: error))
        }
    }

    private static func summary(from status: SeerStatus) -> String {
        if let version = status.version, !version.isEmpty {
            return "Version \(version)"
        }
        return "Connected"
    }

    private static func message(for error: Error) -> String {
        if let appError = error as? AppError { return appError.userMessage }
        return AppError.unknown("").userMessage
    }

    // MARK: - Discovery

    /// Featured hero content: trending titles (movies + TV) from the Seerr
    /// instance, mapped to `MediaItem`s and capped at `limit`. Returns `[]` when
    /// unconfigured so the hero seam is inert until a server is connected.
    public func trending(limit: Int) async throws -> [MediaItem] {
        guard config.isConfigured, limit > 0 else { return [] }
        let page = try await client.trending()
        return SeerMapper.mediaItems(from: page, limit: limit)
    }

    /// Multi-search for movies/TV via Seerr's discovery backend.
    public func search(_ query: String) async throws -> [MediaItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard config.isConfigured, !trimmed.isEmpty else { return [] }
        let page = try await client.search(query: trimmed)
        return SeerMapper.mediaItems(from: page)
    }

    /// The current request/availability state for a discovery title, fetched fresh
    /// from Seerr by its TMDB id. Lets a discovery detail page refresh itself on
    /// (re)open so a title requested in an earlier visit shows "Requested"/
    /// "Downloading" instead of a stale "Request" seeded from the search result.
    ///
    /// Returns `nil` when unconfigured, when the item isn't a movie/series with a
    /// TMDB id, or when the lookup fails — the caller then just keeps the seeded
    /// state. An untracked (never-requested) title decodes as `.unknown`.
    public func availability(for item: MediaItem) async -> (MediaAvailabilityStatus, Double?)? {
        guard config.isConfigured,
              let mediaType = SeerMapper.requestMediaType(for: item),
              let tmdbID = SeerMapper.tmdbID(for: item),
              let details = try? await client.mediaDetails(mediaType: mediaType, tmdbID: tmdbID)
        else { return nil }
        let status = details.mediaInfo?.status.flatMap(MediaAvailabilityStatus.init(rawValue:)) ?? .unknown
        let progress = SeerMapper.downloadProgress(from: details.mediaInfo?.downloadStatus)
        return (status, progress)
    }

    // MARK: - Users

    /// All Seerr users, for the "requests are made as" mapping in Settings.
    /// Fetched as **admin** (the acting user only matters for `request`), paged to
    /// completion, and sorted by display name. Returns `[]` when unconfigured.
    public func users() async throws -> [SeerUser] {
        guard config.isConfigured else { return [] }
        var collected: [SeerUserDTO] = []
        var skip = 0
        let take = 100
        while true {
            let page = try await client.users(take: take, skip: skip)
            collected.append(contentsOf: page.results)
            let total = page.pageInfo?.results ?? collected.count
            skip += page.results.count
            // Stop when a page is short/empty or we've collected the reported total.
            if page.results.isEmpty || collected.count >= total { break }
            if skip > 5000 { break } // safety cap for pathological instances
        }
        let base = config.baseURL
        return collected
            .map { SeerUser.from($0, baseURL: base) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Requests

    /// One-tap request for a not-in-library title, made **as** `actingUserID`
    /// (that Seerr user's quota / approval flow / default quality profile), or as
    /// admin when `nil`.
    ///
    /// - **Mapped user:** omits `serverId`/`profileId`/`rootFolder` so Overseerr
    ///   applies *that user's* defaults (never silently seeds the admin default —
    ///   that would file under the user with the admin's server/profile).
    /// - **Admin (unmapped):** seeds the default Radarr/Sonarr server itself, since
    ///   Seerr won't apply defaults for an omitted body with no user context.
    ///
    /// Returns a ``SeerRequestOutcome`` — success carries the resulting
    /// availability (`.pending` = created, awaiting approval), failure a specific
    /// user-facing reason. Never throws; transport errors map to `.unreachable`.
    @discardableResult
    public func request(_ item: MediaItem, actingUserID: Int? = nil) async -> SeerRequestOutcome {
        guard config.isConfigured else { return .failure(.unknown("Seerr isn’t connected.")) }
        guard let mediaType = SeerMapper.requestMediaType(for: item),
              let tmdbID = SeerMapper.tmdbID(for: item)
        else { return .failure(.unknown("This title can’t be requested.")) }

        let isTV = mediaType == "tv"
        // Only the admin (unmapped) path seeds a server; a mapped user lets
        // Overseerr resolve their own defaults from the omitted body.
        let server: SeerServiceServer? = actingUserID == nil
            ? (isTV ? await defaultSonarr() : await defaultRadarr())
            : nil

        let body = SeerRequestBody(
            mediaType: mediaType,
            mediaId: tmdbID,
            seasons: isTV ? .all : nil,
            is4k: false,
            serverId: server?.id,
            profileId: server?.activeProfileId,
            rootFolder: server?.activeDirectory,
            languageProfileId: isTV ? server?.activeLanguageProfileId : nil
        )

        do {
            let result = try await client.createRequest(body, actingUserID: actingUserID)
            switch result {
            case let .created(response):
                if let raw = response?.media?.status,
                   let status = MediaAvailabilityStatus(rawValue: raw) {
                    return .success(status)
                }
                // No decodable media status (e.g. a 202) — a fresh request is
                // pending by definition.
                return .success(.pending)
            case let .failed(status, message):
                return .failure(.classify(status: status, message: message))
            }
        } catch {
            return .failure(.unreachable)
        }
    }

    private func defaultRadarr() async -> SeerServiceServer? {
        if let cached = cachedRadarr { return cached }
        // Only cache a *successful* fetch. A transient failure (timeout, 401,
        // network blip) must stay uncached so the next request retries — caching
        // it would masquerade as "no servers" and permanently drop the default
        // serverId/profileId/rootFolder for the rest of the session.
        guard let resolved = try? await client.radarrServers() else { return nil }
        let chosen = Self.pickDefault(resolved)
        cachedRadarr = .some(chosen)
        return chosen
    }

    private func defaultSonarr() async -> SeerServiceServer? {
        if let cached = cachedSonarr { return cached }
        guard let resolved = try? await client.sonarrServers() else { return nil }
        let chosen = Self.pickDefault(resolved)
        cachedSonarr = .some(chosen)
        return chosen
    }

    /// Picks the `isDefault` (non-4K) server, falling back to the first entry.
    private static func pickDefault(_ servers: [SeerServiceServer]?) -> SeerServiceServer? {
        guard let servers, !servers.isEmpty else { return nil }
        if let def = servers.first(where: { ($0.isDefault ?? false) && !($0.is4k ?? false) }) {
            return def
        }
        if let def = servers.first(where: { $0.isDefault ?? false }) {
            return def
        }
        return servers.first
    }
}

/// Builds the app's `SeerService`. In production `AppState` injects the shared
/// household connection store (user-independent Keychain); the in-memory default
/// here is only for tests/previews.
public enum SeerServiceFactory {
    @MainActor
    public static func make(
        http: HTTPClient = URLSessionHTTPClient(),
        connectionStore: SeerConnectionStoring? = nil,
        legacyCredentialStore: SeerCredentialStoring? = nil
    ) -> SeerService {
        SeerService(
            connectionStore: connectionStore ?? InMemorySeerConnectionStore(),
            legacyCredentialStore: legacyCredentialStore ?? defaultLegacyCredentialStore(),
            http: http
        )
    }

    /// Legacy per-profile credential store, used ONLY for the one-time migration
    /// of an existing connection into the shared household slot.
    public static func defaultLegacyCredentialStore() -> SeerCredentialStoring {
        #if canImport(Security)
        return KeychainSeerCredentialStore()
        #else
        return InMemorySeerCredentialStore()
        #endif
    }
}
