import Foundation

import CoreModels

/// Fences AetherEngine probe publications to the active adapter load.
struct PlozzigenProbePublicationGate {
    private(set) var currentGeneration: UInt = 0
    private(set) var currentRange: SourceDynamicRange?
    private var isActive = false

    mutating func beginLoad() -> UInt {
        currentGeneration &+= 1
        currentRange = nil
        isActive = true
        return currentGeneration
    }

    mutating func invalidate() {
        currentGeneration &+= 1
        currentRange = nil
        isActive = false
    }

    mutating func record(
        _ range: SourceDynamicRange,
        generation: UInt
    ) -> Bool {
        guard accepts(generation) else { return false }
        currentRange = range
        return true
    }

    func accepts(_ generation: UInt) -> Bool {
        isActive && generation == currentGeneration
    }

    /// Load completion may arrive after Aether has already advanced the adapter
    /// from loading to ready. Only generation validity and engine failure matter.
    func acceptsLoadCompletion(
        _ generation: UInt,
        engineHasError: Bool
    ) -> Bool {
        accepts(generation) && !engineHasError
    }
}
