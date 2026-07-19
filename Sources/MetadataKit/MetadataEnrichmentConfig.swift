import Foundation
import CoreModels

/// Ordering and enablement of external metadata sources — expressed as **data**, so a
/// source can be promoted, demoted, or switched off from configuration with no code
/// change.
///
/// The user model is a **single ordered list with a "Disabled" divider**: enabled
/// sources sit above the divider in priority order (top = highest), disabled sources
/// below. Position expresses **both** priority and enablement — there is no separate
/// Primary/Secondary/Off role any more.
///
/// It layers two inputs:
///   1. a per-field / per-content-type ``MetadataPriorityPolicy`` (the Step 3 tables —
///      which sources serve which field, in what order), used as the **default** order
///      before the user reorders anything, and
///   2. the user's single global ``order`` + a ``disabledSources`` set.
///
/// ``orderedSources(for:query:)`` combines them into the concrete fallback order the
/// pipeline walks. Its key safety property: **an un-reordered config is byte-identical
/// to the pre-reorder per-field behavior** — the per-field policy chains drive ordering
/// until the user actually reorders, at which point the single global ``order`` takes
/// over for every field (``usesGlobalOrder``). Disabled sources are always excluded.
public struct MetadataEnrichmentConfig: Sendable {
    /// Sources removed from enrichment entirely (below the divider, or build-disabled).
    public var disabledSources: Set<MetadataSource>
    /// The single global source order (top = highest priority). Enabled sources lead,
    /// in priority order; disabled sources trail (they are filtered out of enrichment
    /// but kept for a stable, complete order). Seeded from the Step-3-policy-derived
    /// ``defaultBaseOrder``; user reordering permutes it.
    public var order: [MetadataSource]
    /// Whether the user has supplied an explicit reorder. When `false` (default or
    /// disable-only), ``orderedSources(for:query:)`` follows the per-field priority
    /// policy (byte-identical to the pre-reorder behavior). When `true`, the single
    /// global ``order`` drives every field's candidate order.
    public var usesGlobalOrder: Bool
    /// The per-field / per-content-type source-priority tables (the Step 3 policy).
    public var priority: MetadataPriorityPolicy

    public init(
        disabledSources: Set<MetadataSource> = [],
        order: [MetadataSource] = MetadataEnrichmentConfig.defaultBaseOrder,
        usesGlobalOrder: Bool = false,
        priority: MetadataPriorityPolicy = MetadataEnrichmentConfig.defaultPriority
    ) {
        self.disabledSources = disabledSources
        self.order = order
        self.usesGlobalOrder = usesGlobalOrder
        self.priority = priority
    }

    /// The default per-field / per-content-type priority tables (the Step 3 policy).
    public static let defaultPriority: MetadataPriorityPolicy = CurrentMetadataPriority.policy

    /// The recommended global fallback order used when no per-field rule applies, and
    /// the default seed for the single global order: canonical/ids/poster from TheTVDB,
    /// then TMDb artwork, the keyless anime/TV sources, and the factual/last-mile
    /// fallbacks and isolated extras last.
    public static let defaultBaseOrder: [MetadataSource] = [
        .tvdb, .tmdb, .anilist, .tvmaze, .kitsu, .wikidata, .wikipedia, .omdb, .deezer, .musicbrainz,
    ]

    /// Whether `source` participates in enrichment (not disabled).
    public func isEnabled(_ source: MetadataSource) -> Bool {
        !disabledSources.contains(source)
    }

    /// The ordered, enabled sources to try for `field` given `query`'s content type.
    ///
    /// * **Default / disable-only** (``usesGlobalOrder`` == false): starts from the
    ///   per-field priority rule, appends any global-order sources the rule omitted,
    ///   and drops disabled sources — byte-identical to the pre-reorder behavior.
    /// * **Reordered** (``usesGlobalOrder`` == true): the single global ``order`` (minus
    ///   disabled) governs every field. Capability is still enforced downstream by the
    ///   pipeline frontier — an incapable frontmost source is asked, returns nothing,
    ///   and the field falls through — so a provider can never win a field it can't
    ///   serve.
    public func orderedSources(for field: MetadataField, query: MetadataQuery) -> [MetadataSource] {
        if usesGlobalOrder {
            return order.filter { !disabledSources.contains($0) }
        }
        let context = MetadataPriorityContext(rawValue: Self.contextRawValue(for: field, query: query))
        let ruled = priority.sources(for: Self.ruleField(for: field), context: context)
        var ordered: [MetadataSource] = []
        var seen: Set<MetadataSource> = []
        for source in ruled + order where seen.insert(source).inserted {
            ordered.append(source)
        }
        return ordered.filter { !disabledSources.contains($0) }
    }

    /// The raw priority-context string for a `field` + `query`, mirroring the scheme
    /// ``CurrentMetadataPriority`` builds (`artwork.<type>.<kind>`,
    /// `overview.<type>`). Fields without a dedicated table fall back to
    /// `<field>.<type>` (usually unruled → global order).
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
    /// instead of falling through to the global order.
    static func ruleField(for field: MetadataField) -> MetadataField {
        switch artworkKind(for: field) {
        case .hero: return .backdropURL
        case .poster: return .posterURL
        case .thumbnail: return .episodeThumbnail
        case .logo: return .logoURL
        case .none: return field
        }
    }

    // MARK: - User overrides

    /// Returns a copy of this (Info.plist / code-default) baseline with a user's
    /// persisted ``MetadataProviderSettings`` layered on top — the reorder/enable
    /// override. `AppShell` applies this at composition time; the Info.plist-sourced
    /// baseline is never mutated and the merge is a no-op unless the user actually
    /// customized something.
    ///
    /// Layering rules, chosen so the baseline is preserved wherever the user hasn't
    /// spoken:
    ///   * **Disabled set:** the build baseline's disabled sources, plus the user's
    ///     explicitly-disabled sources, minus the user's explicitly-enabled sources (so
    ///     a user can re-enable a build-disabled source by placing it above the
    ///     divider). Only tokens this build knows (the baseline ``order`` set) are
    ///     honored — a stale/foreign token is dropped, never materialized as a phantom
    ///     source.
    ///   * **Order:** the user's placed enabled sources lead in their sequence; any
    ///     baseline source the user didn't place keeps its baseline position, appended
    ///     after; disabled sources trail. So a provider a newer build adds is never
    ///     dropped by an older saved order.
    ///   * **``usesGlobalOrder``:** set only when the user's effective *enabled* order
    ///     actually differs from the baseline enabled order — a real reorder. Merely
    ///     disabling a source keeps the per-field policy chains (nothing was reordered),
    ///     preserving byte-identical ordering for the sources that remain.
    ///
    /// An **empty** override returns `self` unchanged.
    public func merged(withUserOverrides overrides: MetadataProviderSettings) -> MetadataEnrichmentConfig {
        guard !overrides.isEmpty else { return self }

        let known = Set(order)
        let userEnabled = overrides.enabledOrder.map { MetadataSource(rawValue: $0) }.filter { known.contains($0) }
        let userDisabled = overrides.disabledOrder.map { MetadataSource(rawValue: $0) }.filter { known.contains($0) }
        let userEnabledSet = Set(userEnabled)

        var effectiveDisabled = disabledSources
        for source in userDisabled { effectiveDisabled.insert(source) }
        for source in userEnabledSet { effectiveDisabled.remove(source) }

        // Effective global order: user-placed enabled sources first (their sequence),
        // then any baseline source the user didn't place (baseline order), then the
        // disabled sources trailing.
        var seen: Set<MetadataSource> = []
        var enabledEffective: [MetadataSource] = []
        for source in userEnabled where !effectiveDisabled.contains(source) && seen.insert(source).inserted {
            enabledEffective.append(source)
        }
        for source in order where !effectiveDisabled.contains(source) && seen.insert(source).inserted {
            enabledEffective.append(source)
        }
        var disabledTrail: [MetadataSource] = []
        for source in userDisabled where effectiveDisabled.contains(source) && seen.insert(source).inserted {
            disabledTrail.append(source)
        }
        for source in order where effectiveDisabled.contains(source) && seen.insert(source).inserted {
            disabledTrail.append(source)
        }
        let effectiveOrder = enabledEffective + disabledTrail

        // A real reorder (vs a disable-only change) is detected by comparing the
        // effective enabled order to the baseline enabled order (same set, disabled
        // removed). Only a real reorder switches enrichment onto the single global order.
        let baselineEnabled = order.filter { !effectiveDisabled.contains($0) }
        let reordered = enabledEffective != baselineEnabled

        return MetadataEnrichmentConfig(
            disabledSources: effectiveDisabled,
            order: effectiveOrder,
            usesGlobalOrder: reordered,
            priority: priority
        )
    }

    // MARK: - Bundle resolution

    /// Reads the build baseline from the app bundle so a build can disable a source
    /// without code. The `MetadataProviderRoles` Info.plist key holds a comma-separated
    /// `source:role` list, e.g. `"tmdb:disabled"`. In the enabled+order model only
    /// `disabled` is meaningful (it removes the source); any other role leaves the
    /// source enabled. Unknown/foreign tokens are ignored.
    public static func resolved(bundle: Bundle = .main) -> MetadataEnrichmentConfig {
        var disabled: Set<MetadataSource> = []
        if let raw = bundle.object(forInfoDictionaryKey: "MetadataProviderRoles") as? String {
            disabled = parseDisabledSources(raw)
        }
        return MetadataEnrichmentConfig(disabledSources: disabled)
    }

    /// Parses a `"source:role,source:role"` string into the set of sources the build
    /// disables. Whitespace is tolerated; only `disabled` removes a source, so a typo in
    /// the role never silently disables one.
    static func parseDisabledSources(_ raw: String) -> Set<MetadataSource> {
        var disabled: Set<MetadataSource> = []
        for pair in raw.split(separator: ",") {
            let parts = pair.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2, !parts[0].isEmpty else { continue }
            if parts[1].lowercased() == "disabled" {
                disabled.insert(MetadataSource(rawValue: parts[0]))
            }
        }
        return disabled
    }
}
