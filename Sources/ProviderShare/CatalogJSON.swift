import Foundation

/// The catalog's single JSON scalar codec for `metadata_values`/`enrichment`
/// payloads. Pure and stateless — a plain `JSONEncoder`/`JSONDecoder` round-trip
/// with best-effort (`try?`) semantics identical to the store's original inline
/// helpers, extracted so both `ShareCatalogStore` and the pure
/// `ShareCatalogReadProjection`/`ShareSeriesReconciler` share one encode/decode
/// contract instead of each owning a copy.
enum CatalogJSON {
    static func encode<T: Encodable>(_ value: T?) -> String? {
        guard let value else { return nil }
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ json: String?) -> T? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
