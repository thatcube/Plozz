import Foundation
import Observation

// MARK: - Store

/// Persists the single device-local "Developer Mode" flag. This is intentionally
/// **not** synced (no iCloud, no pairing transfer) and **not** per-profile — it
/// is a property of this one install, mirroring how Apple's own hidden developer
/// affordances stay on the device they were unlocked on.
public protocol DeveloperModeStoring: Sendable {
    func loadIsEnabled() -> Bool
    func saveIsEnabled(_ isEnabled: Bool)
}

public final class DeveloperModeStore: DeveloperModeStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "com.plozz.developerModeEnabled"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func loadIsEnabled() -> Bool {
        defaults.bool(forKey: key)
    }

    public func saveIsEnabled(_ isEnabled: Bool) {
        defaults.set(isEnabled, forKey: key)
    }
}

// MARK: - Observable model

/// Owns the runtime "Developer Mode" flag and the hidden unlock gesture that
/// toggles it on. When off (the default in **every** build — Debug, branded, and
/// release alike), the developer/diagnostic rows in Settings stay hidden. A user
/// reveals them by activating the Version row seven times in quick succession
/// (tap on iOS/iPadOS, remote-select on tvOS), the classic "tap the build number"
/// affordance. Once on, a "Turn Off Developer Mode" control hides them again.
///
/// A shared singleton keeps wiring trivial: the flag is one per device, so the
/// three Settings surfaces (tvOS, iOS split, iOS stacked) reference
/// `DeveloperModeModel.shared` directly. Reading `isEnabled` inside a SwiftUI
/// `body` registers the usual Observation dependency, so toggling it live shows
/// or hides the rows without any manual invalidation.
@MainActor
@Observable
public final class DeveloperModeModel {
    /// Shared device-wide instance. Tests build their own with an injected store.
    public static let shared = DeveloperModeModel()

    /// Whether the hidden developer/diagnostic rows are currently revealed.
    public private(set) var isEnabled: Bool

    private let store: DeveloperModeStoring

    /// How many activations of the Version row unlock developer mode, and the
    /// window within which they must occur. A stale tap streak resets so idle
    /// re-taps never accidentally unlock.
    public static let requiredActivations = 7
    private static let activationWindow: TimeInterval = 3

    private var activationCount = 0
    private var lastActivationAt: Date = .distantPast

    public init(store: DeveloperModeStoring = DeveloperModeStore()) {
        self.store = store
        self.isEnabled = store.loadIsEnabled()
    }

    /// Result of one activation of the hidden unlock control.
    public enum UnlockOutcome: Equatable, Sendable {
        /// Developer mode was already on; the tap did nothing.
        case alreadyEnabled
        /// More taps are needed. `remaining` counts down; only surfaced by the UI
        /// once the user is clearly mid-gesture (small remaining count).
        case progress(remaining: Int)
        /// This activation crossed the threshold and just switched it on.
        case justEnabled
    }

    /// Registers one activation of the Version row and reports whether developer
    /// mode just unlocked. Activations outside `activationWindow` of the previous
    /// one restart the count.
    @discardableResult
    public func registerUnlockActivation(now: Date = Date()) -> UnlockOutcome {
        if isEnabled { return .alreadyEnabled }

        if now.timeIntervalSince(lastActivationAt) > Self.activationWindow {
            activationCount = 0
        }
        lastActivationAt = now
        activationCount += 1

        if activationCount >= Self.requiredActivations {
            activationCount = 0
            setEnabled(true)
            return .justEnabled
        }
        return .progress(remaining: Self.requiredActivations - activationCount)
    }

    /// Turns developer mode off and re-hides the gated rows. The count resets so
    /// re-unlocking requires the full gesture again.
    public func disable() {
        activationCount = 0
        setEnabled(false)
    }

    private func setEnabled(_ newValue: Bool) {
        guard isEnabled != newValue else { return }
        isEnabled = newValue
        store.saveIsEnabled(newValue)
    }
}
