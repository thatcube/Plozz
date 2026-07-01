import Foundation
import CryptoKit
import CoreModels
import CoreNetworking

/// Low-level Last.fm 2.0 API calls with on-device request signing.
///
/// Every authenticated Last.fm method carries an `api_sig` = MD5 of all request
/// params (except `format`/`callback`) sorted by name, concatenated as
/// `name+value`, with the shared secret appended. Auth reads (`auth.getToken`,
/// `auth.getSession`) are signed GETs; writes (`track.updateNowPlaying`,
/// `track.scrobble`) are signed `application/x-www-form-urlencoded` POSTs.
struct LastFmClient: Sendable {
    let config: LastFmConfig
    let http: HTTPClient

    init(config: LastFmConfig, http: HTTPClient) {
        self.config = config
        self.http = http
    }

    private var baseURL: URL { config.apiBaseURL }
    private static let apiPath = "/2.0/"

    // MARK: - Auth

    /// `auth.getToken` — requests an unauthorized token the user approves on the web.
    func getToken() async throws -> String {
        let params = signed(["method": "auth.getToken"])
        let endpoint = Endpoint(
            method: .get,
            path: Self.apiPath,
            queryItems: params.map { URLQueryItem(name: $0.key, value: $0.value) }
        )
        let json = try await sendJSON(endpoint)
        if let token = json["token"] as? String { return token }
        throw Self.error(from: json)
    }

    /// `auth.getSession` — exchanges an approved token for a durable session key.
    /// Throws `LastFmAPIError` (code 14) while the token is still unauthorized.
    func getSession(token: String) async throws -> LastFmTokens {
        let params = signed(["method": "auth.getSession", "token": token])
        let endpoint = Endpoint(
            method: .get,
            path: Self.apiPath,
            queryItems: params.map { URLQueryItem(name: $0.key, value: $0.value) }
        )
        let json = try await sendJSON(endpoint)
        if let session = json["session"] as? [String: Any],
           let key = session["key"] as? String {
            let name = session["name"] as? String ?? "Last.fm"
            return LastFmTokens(sessionKey: key, username: name)
        }
        throw Self.error(from: json)
    }

    // MARK: - Scrobbling

    /// `track.updateNowPlaying` — shows the track as "Scrobbling now" on the
    /// user's profile. Not persisted to history; refreshed on start/resume.
    func updateNowPlaying(_ params: LastFmTrackParams, sessionKey: String) async throws {
        var body = params.formFields
        body["method"] = "track.updateNowPlaying"
        body["sk"] = sessionKey
        _ = try await sendJSON(postEndpoint(signed(body)))
    }

    /// `track.scrobble` — records a completed play in the user's history at the
    /// UTC `timestamp` the track started.
    func scrobble(_ params: LastFmTrackParams, timestamp: Int, sessionKey: String) async throws {
        var body = params.formFields
        body["method"] = "track.scrobble"
        body["sk"] = sessionKey
        body["timestamp"] = String(timestamp)
        _ = try await sendJSON(postEndpoint(signed(body)))
    }

    // MARK: - Request building

    /// Adds `api_key`, computes the `api_sig` over the (secret-appended) sorted
    /// params, then adds `api_sig` + `format=json` for the actual request. The
    /// signature is computed over the RAW values before any transport encoding.
    private func signed(_ params: [String: String]) -> [String: String] {
        var result = params
        result["api_key"] = config.apiKey ?? ""
        let signatureBase = result
            .sorted { $0.key < $1.key }
            .map { $0.key + $0.value }
            .joined()
        result["api_sig"] = Self.md5(signatureBase + (config.sharedSecret ?? ""))
        result["format"] = "json"
        return result
    }

    private func postEndpoint(_ params: [String: String]) -> Endpoint {
        let body = params
            .map { "\(Self.formEncode($0.key))=\(Self.formEncode($0.value))" }
            .joined(separator: "&")
        return Endpoint(
            method: .post,
            path: Self.apiPath,
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            body: Data(body.utf8)
        )
    }

    /// Sends and parses the JSON object body. Last.fm returns its API-error
    /// envelope both as HTTP 200 bodies and behind 403s (mapped to
    /// `AppError.unauthorized` by the transport) — the caller distinguishes the
    /// pending-authorization case, so a 403 is surfaced as error code 14.
    private func sendJSON(_ endpoint: Endpoint) async throws -> [String: Any] {
        let data: Data
        do {
            (data, _) = try await http.send(endpoint, baseURL: baseURL)
        } catch AppError.unauthorized {
            // 403 during polling means the token isn't authorized yet.
            throw LastFmAPIError(code: 14, message: "Token not authorized")
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private static func error(from json: [String: Any]) -> LastFmAPIError {
        let code = (json["error"] as? Int) ?? 0
        let message = (json["message"] as? String) ?? "Last.fm error \(code)"
        return LastFmAPIError(code: code, message: message)
    }

    // MARK: - Primitives

    static func md5(_ string: String) -> String {
        Insecure.MD5.hash(data: Data(string.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// `application/x-www-form-urlencoded` value encoding (unreserved chars pass
    /// through; everything else is percent-encoded, including spaces as %20).
    static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

/// The metadata fields a Last.fm now-playing/scrobble carries, mapped from a
/// `MusicTrack`. Empty/optional fields are simply omitted from the request.
struct LastFmTrackParams: Equatable {
    var artist: String
    var track: String
    var album: String?
    var durationSeconds: Int?

    init?(_ track: MusicTrack, durationSeconds: TimeInterval) {
        let artist = track.artistName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
        // Last.fm requires a non-empty artist AND track; without both it rejects
        // the call, so skip scrobbling rather than send junk.
        guard !artist.isEmpty, !title.isEmpty else { return nil }
        self.artist = artist
        self.track = title
        if let album = track.albumTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !album.isEmpty {
            self.album = album
        }
        if durationSeconds > 0 {
            self.durationSeconds = Int(durationSeconds.rounded())
        }
    }

    var formFields: [String: String] {
        var fields = ["artist": artist, "track": track]
        if let album { fields["album"] = album }
        if let durationSeconds { fields["duration"] = String(durationSeconds) }
        return fields
    }
}
