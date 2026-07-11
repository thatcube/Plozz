import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Best-effort access to Plex's public TV theme archive, keyed by TVDB series ID.
public enum ThemeMusicArchive {
    public static let host = "tvthemes.plexapp.com"

    public static func url(tvdbID: String?) -> URL? {
        guard let tvdbID = tvdbID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !tvdbID.isEmpty,
              tvdbID.allSatisfy(\.isNumber) else { return nil }
        return URL(string: "https://\(host)/\(tvdbID).mp3")
    }

    public static func resolvedURL(
        tvdbID: String?,
        session: URLSession = .shared
    ) async -> URL? {
        guard let url = url(tvdbID: tvdbID) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 8
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return nil }
            return url
        } catch {
            return nil
        }
    }
}
