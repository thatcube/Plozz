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
    /// **Local proof outranks a provider's availability.** This used to also route to
    /// discovery when an item was flagged not-in-library and the index had no peer.
    /// Written out, that clause could only ever fire on an item the app had *already
    /// validated a playable record for* — so it was index-warmth gating in disguise,
    /// and which page a tap opened depended on whether the index happened to be warm.
    /// It stripped the page of Play, episodes, versions and the cross-server resolver,
    /// and sent it down the discovery load path that never queries a provider at all.
    ///
    /// It is deliberately **not** split per availability case. Every producer that
    /// mints a discovery status also sets `locallyValidatedPlayableSource` false, so
    /// the only way to be validated *and* carry `.pending`/`.deleted` is a merge in
    /// which a genuine library member folded in — i.e. the viewer owns a copy and
    /// Seerr's record is stale or describes a *request*, not library membership.
    /// `.processing` plus owned is the routine "Radarr just imported it" race.
    ///
    /// The accepted failure is a title whose validation came from a stale row on a
    /// server that no longer holds the file: it shows a library page and fails loudly
    /// at playback instead of silently showing a request page. That is the same
    /// failure any ordinary library item already has, and it is deterministic rather
    /// than dependent on index warmth.
    ///
    /// This is now the exact complement of ``MediaItem/ownershipPresentation(additionalSources:)``'s
    /// `canPlay`, and of `HeroCTA`'s `hasValidatedPlayableSource` precedence. That
    /// identity is the invariant the classifier exists to enforce, not an accident —
    /// do not "simplify" one side of it away.
    public static func isDiscoveryRouting(
        _ item: MediaItem,
        identitySources: [MediaSourceRef]
    ) -> Bool {
        !item.hasPlayableLibraryTarget(additionalSources: identitySources)
    }

    /// Index-free badge predicate — poster corner marks and card indicator state.
    ///
    /// Deliberately **keeps** the availability clause that routing drops, and the two
    /// are allowed to differ. ``MediaItem/locallyValidatedPlayableSource`` defaults to
    /// `true`, so a badge resting on it alone would fail *open* — every future producer
    /// that forgot to set it false would silently claim ownership, and claiming owned
    /// for something that dead-ends is the worse of the two errors on a card. The
    /// availability clause is the fail-closed half.
    ///
    /// The card/page disagreement that would otherwise leave behind is fixed at the
    /// producer instead: ``MediaItemMerger`` clears a discovery availability once a
    /// genuinely validated member has folded in, so no item reaches a card both
    /// validated and flagged.
    ///
    /// Index-free by signature, and that is load-bearing: marks cannot flicker as the
    /// index warms, because warming cannot reach this function. Threading liveness
    /// (`isWarm`/`staleAccounts`) in here would turn every warm publish into a full
    /// card-wave re-render — and warmth is a property of this session's scan, not of
    /// reachability at press time, so it would be wrong in both directions anyway.
    /// Liveness belongs at source selection and playback, where it is checked once per
    /// interaction and can fail over.
    public static func isNotOwnedForBadge(_ item: MediaItem) -> Bool {
        item.isNotInLibraryDiscovery || !item.hasPlayableLibraryTarget()
    }
}
