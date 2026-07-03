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
    @ObservationIgnored private let credentialStore: SeerCredentialStoring
    @ObservationIgnored private let http: HTTPClient

    /// Cached default Radarr/Sonarr servers (fetched lazily on first request so a
    /// one-tap request can seed `serverId`/`profileId`/`rootFolder`). The double
    /// optional distinguishes "not fetched" (`nil`) from "fetched, none found"
    /// (`.some(nil)`).
    @ObservationIgnored private var cachedRadarr: SeerServiceServer??
    @ObservationIgnored private var cachedSonarr: SeerServiceServer??

    public init(credentialStore: SeerCredentialStoring, http: HTTPClient = URLSessionHTTPClient()) {
        self.credentialStore = credentialStore
        self.http = http
        self.config = Self.loadConfig(from: credentialStore)
    }

    /// Whether a server URL + API key are saved (feature is set up).
    public var isConfigured: Bool { config.isConfigured }

    /// The saved server URL, for pre-filling the Settings field on re-entry.
    public var savedBaseURLString: String? { config.baseURL?.absoluteString }

    private var client: SeerClient { SeerClient(config: config, http: http) }

    private static func loadConfig(from store: SeerCredentialStoring) -> SeerConfig {
        guard let creds = store.load() else { return SeerConfig() }
        return SeerConfig(baseURL: creds.baseURL, apiKey: creds.apiKey, userId: creds.userId)
    }

    // MARK: - Lifecycle

    /// Switches to a household profile's own Seerr connection. Each profile
    /// connects independently; the default profile uses `nil` (legacy
    /// un-namespaced storage). Reloads credentials, then re-resolves status.
    public func setActiveProfile(namespace: String?) async {
        credentialStore.setNamespace(namespace)
        config = Self.loadConfig(from: credentialStore)
        cachedRadarr = nil
        cachedSonarr = nil
        phase = .unknown
        await refreshStatus()
    }

    /// Resolves the current status: probes `/api/v1/status` when credentials are
    /// saved (so the Settings row reflects reachability). Safe to call repeatedly.
    public func refreshStatus() async {
        guard config.isConfigured else { phase = .unconfigured; return }
        await probe()
    }

    /// Validates + saves an entered configuration ("Connect / Test"). Probes the
    /// server first and only persists the credentials when it responds; a bad URL
    /// or key surfaces as `.failed` and nothing is stored.
    public func connect(baseURL: URL, apiKey: String, userId: Int? = nil) async {
        let trial = SeerConfig(baseURL: baseURL, apiKey: apiKey, userId: userId)
        guard trial.isConfigured else {
            phase = .failed("Enter both a server address and an API key.")
            return
        }
        phase = .connecting
        do {
            let status = try await SeerClient(config: trial, http: http).status()
            // Reachable — persist and adopt.
            let creds = SeerCredentials(baseURL: baseURL, apiKey: trial.apiKey ?? apiKey, userId: userId)
            try? credentialStore.save(creds)
            config = trial
            cachedRadarr = nil
            cachedSonarr = nil
            phase = .connected(summary: Self.summary(from: status))
        } catch {
            phase = .failed(Self.message(for: error))
        }
    }

    /// Disconnects: clears the saved credentials and resets to unconfigured.
    public func disconnect() {
        try? credentialStore.clear()
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

    // MARK: - Requests

    /// One-tap request for a title that isn't yet in the library. Derives the
    /// media type + TMDB id from the item, seeds the default Radarr/Sonarr server
    /// (Seerr doesn't apply defaults for an omitted body), requests **all**
    /// seasons for TV, and returns the resulting availability status so the UI
    /// can flip to Pending/Processing.
    ///
    /// - Throws: `AppError.invalidResponse` if the item carries no TMDB id,
    ///   `AppError.conflict` if it was already requested, or transport errors.
    @discardableResult
    public func request(_ item: MediaItem) async throws -> MediaAvailabilityStatus {
        guard config.isConfigured else { throw AppError.unauthorized }
        guard let mediaType = SeerMapper.requestMediaType(for: item),
              let tmdbID = SeerMapper.tmdbID(for: item)
        else { throw AppError.invalidResponse }

        let isTV = mediaType == "tv"
        // Seerr does NOT apply Radarr/Sonarr defaults for an omitted body, so we
        // seed them ourselves. A best-effort fetch failure just omits them (the
        // request still gets created); a later request retries the lookup.
        let server = isTV ? await defaultSonarr() : await defaultRadarr()

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

        let response = try await client.createRequest(body)
        if let raw = response?.media?.status,
           let status = MediaAvailabilityStatus(rawValue: raw) {
            return status
        }
        // No decodable media status (e.g. a 202) — a freshly created request is
        // pending by definition.
        return .pending
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

/// Builds the app's `SeerService`, choosing a Keychain-backed credential store on
/// Apple platforms and an in-memory one elsewhere.
public enum SeerServiceFactory {
    @MainActor
    public static func make(
        http: HTTPClient = URLSessionHTTPClient(),
        credentialStore: SeerCredentialStoring? = nil,
        namespace: String? = nil
    ) -> SeerService {
        let store = credentialStore ?? defaultCredentialStore()
        store.setNamespace(namespace)
        return SeerService(credentialStore: store, http: http)
    }

    public static func defaultCredentialStore() -> SeerCredentialStoring {
        #if canImport(Security)
        return KeychainSeerCredentialStore()
        #else
        return InMemorySeerCredentialStore()
        #endif
    }
}
