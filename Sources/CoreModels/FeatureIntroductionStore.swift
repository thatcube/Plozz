import Foundation

/// A versioned, device-local introduction that should be shown once.
///
/// The introduction is app-wide rather than profile-scoped. Feature-specific
/// onboarding can still edit the active profile's settings, but switching to
/// another existing profile must not replay the same announcement.
public struct FeatureIntroduction: Hashable, Identifiable, Sendable {
    public let id: String
    public let version: Int

    public init(id: String, version: Int) {
        precondition(!id.isEmpty)
        precondition(version > 0)
        self.id = id
        self.version = version
    }

    public static let navigationStyles = FeatureIntroduction(
        id: "navigation-styles",
        version: 1
    )
}

public protocol FeatureIntroductionStoring: Sendable {
    func needsPresentation(_ introduction: FeatureIntroduction) -> Bool
    func markCompleted(_ introduction: FeatureIntroduction)
}

/// Stores the latest completed version for each feature introduction.
///
/// Raising a feature's version presents it once again without inventing another
/// key or disturbing any unrelated introduction.
public final class FeatureIntroductionStore: FeatureIntroductionStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let keyPrefix: String

    public init(
        defaults: UserDefaults = .standard,
        keyPrefix: String = "com.plozz.featureIntroduction"
    ) {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    public func needsPresentation(_ introduction: FeatureIntroduction) -> Bool {
        defaults.integer(forKey: key(for: introduction)) < introduction.version
    }

    public func markCompleted(_ introduction: FeatureIntroduction) {
        let key = key(for: introduction)
        defaults.set(
            max(defaults.integer(forKey: key), introduction.version),
            forKey: key
        )
    }

    private func key(for introduction: FeatureIntroduction) -> String {
        "\(keyPrefix).\(introduction.id)"
    }
}

public protocol ProfileAppearanceSetupStoring: Sendable {
    func isPending(profileID: String) -> Bool
    func markPending(profileID: String)
    func markCompleted(profileID: String)
}

/// Durable resume marker for a new profile's Theme + Navigation flow.
///
/// This is separate from the app-wide feature introduction: old inactive
/// profiles must not be prompted on switch, while a newly-created profile must
/// resume its own unfinished setup after relaunch.
public final class ProfileAppearanceSetupStore: ProfileAppearanceSetupStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let keyPrefix: String

    public init(
        defaults: UserDefaults = .standard,
        keyPrefix: String = "com.plozz.profileAppearanceSetup"
    ) {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    public func isPending(profileID: String) -> Bool {
        defaults.bool(forKey: key(profileID))
    }

    public func markPending(profileID: String) {
        defaults.set(true, forKey: key(profileID))
    }

    public func markCompleted(profileID: String) {
        defaults.removeObject(forKey: key(profileID))
    }

    private func key(_ profileID: String) -> String {
        "\(keyPrefix).\(profileID)"
    }
}
