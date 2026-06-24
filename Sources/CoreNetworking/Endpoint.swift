import Foundation

public enum HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case delete = "DELETE"
}

/// A description of a single HTTP request, independent of how it's executed.
///
/// Providers build `Endpoint`s and hand them to `HTTPClient`, which keeps the
/// transport (URLSession), header redaction, and error mapping in one place.
public struct Endpoint: Sendable {
    public var method: HTTPMethod
    /// Path relative to the server base URL, e.g. `/QuickConnect/Initiate`.
    public var path: String
    public var queryItems: [URLQueryItem]
    public var headers: [String: String]
    public var body: Data?

    public init(
        method: HTTPMethod = .get,
        path: String,
        queryItems: [URLQueryItem] = [],
        headers: [String: String] = [:],
        body: Data? = nil
    ) {
        self.method = method
        self.path = path
        self.queryItems = queryItems
        self.headers = headers
        self.body = body
    }

    /// Convenience for a JSON `POST`/`GET` carrying an `Encodable` body.
    public func jsonBody<T: Encodable>(_ value: T, encoder: JSONEncoder = JSONEncoder()) throws -> Endpoint {
        var copy = self
        copy.body = try encoder.encode(value)
        copy.headers["Content-Type"] = "application/json"
        return copy
    }
}
