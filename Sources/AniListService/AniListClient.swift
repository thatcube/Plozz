import Foundation
import CoreModels
import CoreNetworking

/// AniList GraphQL API client.
struct AniListClient: Sendable {
    let config: AniListConfig
    let http: HTTPClient

    init(config: AniListConfig, http: HTTPClient) {
        self.config = config
        self.http = http
    }

    private var baseURL: URL { config.apiBaseURL }

    private func headers(accessToken: String) -> [String: String] {
        [
            "Content-Type": "application/json",
            "Accept": "application/json",
            "Authorization": "Bearer \(accessToken)"
        ]
    }

    // MARK: - User

    /// Fetches the authenticated user's profile.
    func viewer(accessToken: String) async throws -> AniListUser {
        let query = """
        query { Viewer { id name } }
        """
        let body = AniListGraphQLBody(query: query)
        let endpoint = try Endpoint(method: .post, path: "", headers: headers(accessToken: accessToken))
            .jsonBody(body)
        let response: AniListGraphQLResponse<AniListViewerData> =
            try await http.decode(AniListGraphQLResponse<AniListViewerData>.self, from: endpoint, baseURL: baseURL)
        guard let viewer = response.data?.Viewer else {
            throw AppError.unknown("AniList: failed to fetch user")
        }
        return AniListUser(id: viewer.id, name: viewer.name)
    }

    // MARK: - OAuth token exchange

    /// Exchanges an authorization code for an access token (code grant flow).
    func exchangeCode(_ code: String) async throws -> String {
        guard let clientID = config.clientID, let clientSecret = config.clientSecret else {
            throw AppError.unknown("AniList: missing client credentials")
        }
        let tokenURL = URL(string: "https://anilist.co/api/v2/oauth/token")!
        let requestBody = AniListTokenExchangeBody(
            grantType: "authorization_code",
            clientId: clientID,
            clientSecret: clientSecret,
            redirectUri: "https://anilist.co/api/v2/oauth/pin",
            code: code
        )
        let endpoint = try Endpoint(method: .post, path: "", headers: [
            "Content-Type": "application/json",
            "Accept": "application/json"
        ]).jsonBody(requestBody)
        let (data, _) = try await http.send(endpoint, baseURL: tokenURL)
        let tokenResponse = try JSONDecoder().decode(AniListTokenExchangeResponse.self, from: data)
        return tokenResponse.accessToken
    }

    // MARK: - Media lookup

    /// Looks up an anime by its AniList ID, MAL ID, or title.
    func findAnime(anilistID: Int?, malID: Int?, title: String?, accessToken: String) async throws -> Int? {
        // Prefer direct AniList ID
        if let id = anilistID { return id }

        // Look up by MAL ID
        if let malID {
            let query = """
            query ($malId: Int) { Media(idMal: $malId, type: ANIME) { id } }
            """
            let variables: [String: AniListVariable] = ["malId": .int(malID)]
            let body = AniListGraphQLBodyWithVars(query: query, variables: variables)
            let endpoint = try Endpoint(method: .post, path: "", headers: headers(accessToken: accessToken))
                .jsonBody(body)
            let response: AniListGraphQLResponse<AniListSearchData> =
                try await http.decode(AniListGraphQLResponse<AniListSearchData>.self, from: endpoint, baseURL: baseURL)
            if let id = response.data?.Media?.id { return id }
        }

        // Fall back to title search
        if let title, !title.isEmpty {
            let query = """
            query ($search: String) { Media(search: $search, type: ANIME) { id } }
            """
            let variables: [String: AniListVariable] = ["search": .string(title)]
            let body = AniListGraphQLBodyWithVars(query: query, variables: variables)
            let endpoint = try Endpoint(method: .post, path: "", headers: headers(accessToken: accessToken))
                .jsonBody(body)
            let response: AniListGraphQLResponse<AniListSearchData> =
                try await http.decode(AniListGraphQLResponse<AniListSearchData>.self, from: endpoint, baseURL: baseURL)
            if let id = response.data?.Media?.id { return id }
        }

        return nil
    }

    // MARK: - Update list

    /// Updates or creates a media list entry (marks progress / status).
    func saveMediaListEntry(
        mediaId: Int,
        status: AniListMediaListStatus?,
        progress: Int?,
        accessToken: String
    ) async throws {
        var variableParts: [String] = ["$mediaId: Int"]
        var assignParts: [String] = ["mediaId: $mediaId"]
        var variables: [String: AniListVariable] = ["mediaId": .int(mediaId)]

        if let status {
            variableParts.append("$status: MediaListStatus")
            assignParts.append("status: $status")
            variables["status"] = .string(status.rawValue)
        }
        if let progress {
            variableParts.append("$progress: Int")
            assignParts.append("progress: $progress")
            variables["progress"] = .int(progress)
        }

        let query = """
        mutation (\(variableParts.joined(separator: ", "))) {
          SaveMediaListEntry (\(assignParts.joined(separator: ", "))) { id status progress }
        }
        """
        let body = AniListGraphQLBodyWithVars(query: query, variables: variables)
        let endpoint = try Endpoint(method: .post, path: "", headers: headers(accessToken: accessToken))
            .jsonBody(body)
        let response: AniListGraphQLResponse<AniListSaveMediaListData> =
            try await http.decode(AniListGraphQLResponse<AniListSaveMediaListData>.self, from: endpoint, baseURL: baseURL)
        if let errors = response.errors, !errors.isEmpty {
            throw AppError.unknown("AniList: \(errors.first?.message ?? "unknown error")")
        }
    }
}

// MARK: - GraphQL request bodies

struct AniListGraphQLBody: Encodable {
    let query: String
}

enum AniListVariable: Encodable {
    case int(Int)
    case string(String)

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .int(let v): try container.encode(v)
        case .string(let v): try container.encode(v)
        }
    }
}

struct AniListGraphQLBodyWithVars: Encodable {
    let query: String
    let variables: [String: AniListVariable]
}

// MARK: - OAuth token exchange bodies

struct AniListTokenExchangeBody: Encodable {
    let grantType: String
    let clientId: String
    let clientSecret: String
    let redirectUri: String
    let code: String

    enum CodingKeys: String, CodingKey {
        case grantType = "grant_type"
        case clientId = "client_id"
        case clientSecret = "client_secret"
        case redirectUri = "redirect_uri"
        case code
    }
}

struct AniListTokenExchangeResponse: Decodable {
    let accessToken: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
    }
}
