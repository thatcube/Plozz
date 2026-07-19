import Foundation
import CoreModels

/// Ordering and enablement of external metadata sources — expressed as **data**, so
/// a source can be promoted, demoted, or switched off from configuration with no
/// code change (the Step 5 "ordering as configuration" requirement).
///
/// It layers two inputs:
///   1. a per-field / per-content-type ``MetadataPriorityPolicy`` (the Step 3
///      tables — which sources serve which field, in what order), and
///   2. a ``ProviderRole`` map (primary / secondary / disabled) applied on top.
///
/// ``orderedSources(for:query:)`` combines them into the concrete fallback order the
/// pipeline walks: disabled sources are dropped, and `primary` sources are stably
/// hoisted ahead of `secondary` ones without disturbing the base table order.
public struct MetadataEnrichmentConfig: Sendable {
    /// Explicit role overrides. A source absent from the map defaults to
    /// ``ProviderRole/primary`` (i.e. the base policy order is used unchanged).
    public var roles: [MetadataSource: ProviderRole]
    /// Content-agnostic fallback order for fields the priority policy has no rule
    /// for (ids, taglines, canonical text). Also supplies sources the per-field rule
    /// omitted, appended after the ruled ones.
    public var baseOrder: [MetadataSource]
    /// The per-field / per-content-type source-priority tables.
    public var priority: MetadataPriorityPolicy

    public init(
        roles: [MetadataSource: ProviderRole] = [:],
        baseOrder: [MetadataSource] = MetadataEnrichmentConfig.defaultBaseOrder,
        priority: MetadataPriorityPolicy = MetadataEnrichmentConfig.defaultPriority
    ) {
        self.roles = roles
        self.baseOrder = baseOrder
        self.priority = priority
    }

    /// The default per-field / per-content-type priority tables (the Step 3 policy).
    public static let defaultPriority: MetadataPriorityPolicy = CurrentMetadataPriority.policy

    /// The recommended global fallback order used when no per-field rule applies:
    /// canonical/ids/poster from TheTVDB, then TMDb artwork, the keyless anime/TV
    /// sources, and the factual/last-mile fallbacks and isolated extras last.
    public static let defaultBaseOrder: [MetadataSource] = [
        .tvdb, .tmdb, .anilist, .tvmaze, .kitsu, .wikidata, .wikipedia, .omdb, .deezer, .musicbrainz,
    ]

    public func role(of source: MetadataSource) -> ProviderRole {
        roles[source] ?? .primary
    }

    public func isEnabled(_ source: MetadataSource) -> Bool {
        role(of: source) != .disabled
    }

    /// The ordered, role-filtered sources to try for `field` given `query`'s content
    /// type. Starts from the per-field priority rule, appends any base-order sources
    /// the rule omitted, drops disabled sources, and stably partitions primary ahead
    /// of secondary.
    public func orderedSources(for field: MetadataField, query: MetadataQuery) -> [MetadataSource] {
        let context = MetadataPriorityContext(rawValue: Self.contextRawValue(for: field, query: query))
        let ruled = priority.sources(for: Self.ruleField(for: field), context: context)
        var ordered: [MetadataSource] = []
        var seen: Set<MetadataSource> = []
        for source in ruled + baseOrder where seen.insert(source).inserted {
            ordered.append(source)
        }
        let enabled = ordered.filter(isEnabled)
        let primary = enabled.filter { role(of: $0) == .primary }
        let secondary = enabled.filter { role(of: $0) == .secondary }
        return primary + secondary
    }

    /// The raw priority-context string for a `field` + `query`, mirroring the scheme
    /// ``CurrentMetadataPriority`` builds (`artwork.<type>.<kind>`,
    /// `overview.<type>`). Fields without a dedicated table fall back to
    /// `<field>.<type>` (usually unruled → base order).
    static func contextRawValue(for field: MetadataField, query: MetadataQuery) -> String {
        let type = query.contentType.rawValue
        if let kind = artworkKind(for: field) {
            return "artwork.\(type).\(kind.rawValue)"
        }
        if field == .overview {
            return "overview.\(type)"
        }
        return "\(field.rawValue).\(type)"
    }

    /// Maps an artwork ``MetadataField`` onto the ``ArtworkKind`` the priority tables
    /// are keyed on. Home-hero and detail-backdrop both resolve through the wide
    /// `hero` chain (one backdrop response serves both screens).
    static func artworkKind(for field: MetadataField) -> ArtworkKind? {
        switch field {
        case .posterURL: return .poster
        case .backdropURL, .homeHero, .detailBackdrop: return .hero
        case .logoURL: return .logo
        case .episodeThumbnail: return .thumbnail
        default: return nil
        }
    }

    /// The canonical field a priority *rule* is keyed on for `field`. The Step 3
    /// tables key every wide-backdrop variant (`homeHero`, `detailBackdrop`,
    /// `backdropURL`) on `.backdropURL`, so those all look up the same hero rule
    /// instead of falling through to the base order.
    static func ruleField(for field: MetadataField) -> MetadataField {
        switch artworkKind(for: field) {
        case .hero: return .backdropURL
        case .poster: return .posterURL
        case .thumbnail: return .episodeThumbnail
        case .logo: return .logoURL
        case .none: return field
        }
    }

    // MARK: - Bundle resolution

    /// Reads role overrides from the app bundle so a build can promote/demote/disable
    /// a source without code. The `MetadataProviderRoles` Info.plist key holds a
    /// comma-separated `source:role` list, e.g. `"tmdb:disabled,wikipedia:secondary"`.
    /// Unknown tokens are ignored; the rest of the config uses the defaults.
    public static func resolved(bundle: Bundle = .main) -> MetadataEnrichmentConfig {
        var roles: [MetadataSource: ProviderRole] = [:]
        if let raw = bundle.object(forInfoDictionaryKey: "MetadataProviderRoles") as? String {
            roles = parseRoles(raw)
        }
        return MetadataEnrichmentConfig(roles: roles)
    }

    /// Parses a `"source:role,source:role"` string into a role map. Whitespace is
    /// tolerated; malformed or unknown-role entries are skipped.
    static func parseRoles(_ raw: String) -> [MetadataSource: ProviderRole] {
        var roles: [MetadataSource: ProviderRole] = [:]
        for pair in raw.split(separator: ",") {
            let parts = pair.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2, !parts[0].isEmpty,
                  let role = ProviderRole(rawValue: parts[1].lowercased())
            else { continue }
            roles[MetadataSource(rawValue: parts[0])] = role
        }
        return roles
    }
}
