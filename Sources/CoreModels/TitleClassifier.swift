import Foundation

/// The single, shared answer to "does the viewer own this title?".
///
/// Before this existed the same decision was written four times — the detail
/// environment, the action coordinator, the poster corner mark and the card indicator
/// state — which is exactly how a card and the page it opens end up disagreeing about
/// whether a title is owned. There is now one implementation and every surface, tvOS
/// and iOS/iPadOS, consumes it.
///
/// ## Two questions, deliberately named apart
///
/// These are *not* one predicate used in four places. They are two questions:
///
/// - ``TitleClassifier/isDiscoveryRouting(_:identitySources:)`` — index-aware: "does
///   this title actually resolve to a library copy anywhere?" Decides whether a page
///   is stripped of its library affordances and shown as a request page.
/// - ``TitleClassifier/isNotOwnedForBadge(_:)`` — index-free: "should this poster wear
///   a *not in your library* corner mark?" Poster cards run hundreds of times per wave
///   and must never do index work per card, so this one judges the item alone.
///
/// `DetailOpenEnvironment`'s original comment says why they differ: *"flagged not in
/// the library" and "actually absent" are different questions, and only the second
/// should strip a page of its library affordances*. An external credit carries
/// `availability == .unknown` because the provider that supplied it has no idea what
/// the viewer owns — that is a statement about the provider, not a finding about the
/// library. Collapsing the two into one Bool regresses whichever side loses.
public struct TitleClassification: Hashable, Sendable {
    /// The universal Plozz identity for the title.
    public let identity: TitleIdentity
    /// Whether a real, locally-validated (or index-supplied) library record exists.
    public let hasPlayableLibraryTarget: Bool
    /// Index-aware routing decision — see the type doc.
    public let isDiscoveryRouting: Bool
    /// Index-free badge decision — see the type doc.
    public let isNotOwnedForBadge: Bool
    /// A schedule placeholder for an episode that has not aired, so exists nowhere.
    public let isUpcomingUnaired: Bool
    /// `nil` for an ordinary library item — absence is *not* `.unknown`, and must
    /// never be mapped to it or every library title becomes a request candidate.
    public let availability: MediaAvailabilityStatus?

    public init(
        identity: TitleIdentity,
        hasPlayableLibraryTarget: Bool,
        isDiscoveryRouting: Bool,
        isNotOwnedForBadge: Bool,
        isUpcomingUnaired: Bool,
        availability: MediaAvailabilityStatus?
    ) {
        self.identity = identity
        self.hasPlayableLibraryTarget = hasPlayableLibraryTarget
        self.isDiscoveryRouting = isDiscoveryRouting
        self.isNotOwnedForBadge = isNotOwnedForBadge
        self.isUpcomingUnaired = isUpcomingUnaired
        self.availability = availability
    }

    public var ownershipPresentation: MediaOwnershipPresentation {
        MediaOwnershipPresentation(hasValidatedPlayableSource: hasPlayableLibraryTarget)
    }

    /// The primary CTA. Deliberately a **function, not a stored property**: it depends
    /// on `downloadProgress`, which ticks on every Seerr poll, and storing it would
    /// make this type unequal on every tick and defeat any cache keyed on it.
    public func cta(downloadProgress: Double?, seerConnected: Bool) -> HeroCTA {
        MediaItem.heroCTA(
            availability: availability,
            downloadProgress: downloadProgress,
            hasValidatedPlayableSource: hasPlayableLibraryTarget,
            seerConnected: seerConnected
        )
    }
}

public enum TitleClassifier {
    /// Classify `item` against the live per-device evidence.
    ///
    /// - Parameters:
    ///   - identitySources: cross-server copies the identity index knows about. Pass
    ///     `[]` on card paths, which must judge the item alone.
    ///   - resolver: the universal identity resolver. Pass ``TitleIdentityResolver/empty``
    ///     where only the ownership answer is needed.
    public static func classify(
        _ item: MediaItem,
        identitySources: [MediaSourceRef] = [],
        resolver: TitleIdentityResolver = .empty
    ) -> TitleClassification {
        TitleClassification(
            identity: resolver.identity(for: item),
            hasPlayableLibraryTarget: item.hasPlayableLibraryTarget(
                additionalSources: identitySources
            ),
            isDiscoveryRouting: isDiscoveryRouting(item, identitySources: identitySources),
            isNotOwnedForBadge: isNotOwnedForBadge(item),
            isUpcomingUnaired: item.isUpcomingUnaired,
            availability: item.availability
        )
    }

    /// Index-aware routing predicate — the detail page and the action coordinator.
    ///
    /// - Note: behavior is byte-for-byte what both call sites did before unification.
    ///   There is a latent precedence question here: a **locally validated** item that
    ///   is flagged not-in-library and has no indexed peer still routes to discovery,
    ///   which hides Play on a copy the app validated. Changing that is a behavior
    ///   change that needs on-device verification, so it is deliberately not made here.
    public static func isDiscoveryRouting(
        _ item: MediaItem,
        identitySources: [MediaSourceRef]
    ) -> Bool {
        !item.hasPlayableLibraryTarget(additionalSources: identitySources)
            || (item.isNotInLibraryDiscovery && identitySources.isEmpty)
    }

    /// Index-free badge predicate — poster corner marks and card indicator state.
    public static func isNotOwnedForBadge(_ item: MediaItem) -> Bool {
        item.isNotInLibraryDiscovery || !item.hasPlayableLibraryTarget()
    }
}
