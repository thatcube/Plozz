import Foundation
import CoreModels

/// Opt-in experiment that moves the hero's dynamic foreground visual update off
/// the same frame as its canonical page/backdrop transition.
enum HeroForegroundStaggerExperiment {
    static let isEnabled =
        ProcessInfo.processInfo.environment["PLZHERO_STAGGERED_FOREGROUND"] == "1"

    /// Long enough to cross several 60 Hz frame boundaries, but still comfortably
    /// inside the existing 280 ms hidden interval before the foreground fades in.
    static let applyDelayNanoseconds: UInt64 = 50_000_000
    static let applyDelayMilliseconds = 50
}

/// Pure identity state for the staggered hero-foreground experiment.
///
/// The view keeps navigation and actions on its canonical index. This state owns
/// only the item identity used to render hidden/non-interactive foreground visuals.
/// Each scheduled update gets a generation so rapid paging, reversal, and set swaps
/// reject stale work before it can become visible.
public struct HeroForegroundItemKey: Hashable, Sendable {
    public let itemID: String
    public let sourceAccountID: String?
    public let kind: String

    public init(itemID: String, sourceAccountID: String?, kind: String) {
        self.itemID = itemID
        self.sourceAccountID = sourceAccountID
        self.kind = kind
    }

    public init(_ item: MediaItem) {
        self.init(
            itemID: item.id,
            sourceAccountID: item.sourceAccountID,
            kind: item.kind.rawValue
        )
    }
}

public struct HeroForegroundStaggerState: Equatable, Sendable {
    public struct Update: Equatable, Sendable {
        public let generation: UInt64
        public let targetItemKey: HeroForegroundItemKey?
    }

    public private(set) var visualItemKey: HeroForegroundItemKey?
    public private(set) var generation: UInt64 = 0

    public init(itemKeys: [HeroForegroundItemKey] = [], canonicalIndex: Int = 0) {
        visualItemKey = Self.itemKey(in: itemKeys, at: canonicalIndex)
    }

    /// Creates the only update that may next change the visual foreground.
    public mutating func schedule(
        itemKeys: [HeroForegroundItemKey],
        canonicalIndex: Int
    ) -> Update {
        generation &+= 1
        return Update(
            generation: generation,
            targetItemKey: Self.itemKey(in: itemKeys, at: canonicalIndex)
        )
    }

    /// Applies an update only if it is still the latest generation and still
    /// targets the canonical item in the current set.
    @discardableResult
    public mutating func apply(
        _ update: Update,
        itemKeys: [HeroForegroundItemKey],
        canonicalIndex: Int
    ) -> Bool {
        let canonicalKey = Self.itemKey(in: itemKeys, at: canonicalIndex)
        guard update.generation == generation,
              update.targetItemKey == canonicalKey
        else {
            return false
        }
        visualItemKey = canonicalKey
        return true
    }

    /// Immediately aligns visuals after the underlying item set changes and
    /// invalidates every update scheduled against the old set.
    public mutating func reseed(
        itemKeys: [HeroForegroundItemKey],
        canonicalIndex: Int
    ) {
        generation &+= 1
        visualItemKey = Self.itemKey(in: itemKeys, at: canonicalIndex)
    }

    /// Resolves the visual identity back to the current set without ever returning
    /// an index for an item that has been removed.
    public func visualIndex(in itemKeys: [HeroForegroundItemKey]) -> Int? {
        guard let visualItemKey else { return nil }
        return itemKeys.firstIndex(of: visualItemKey)
    }

    private static func itemKey(
        in itemKeys: [HeroForegroundItemKey],
        at index: Int
    ) -> HeroForegroundItemKey? {
        guard itemKeys.indices.contains(index) else { return itemKeys.first }
        return itemKeys[index]
    }
}
