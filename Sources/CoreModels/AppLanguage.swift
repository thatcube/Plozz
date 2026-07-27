import Foundation
import Observation

/// The language Plozz draws its own UI in.
///
/// tvOS has **no per-app language control in Settings.app** — unlike iOS, where
/// the system offers one for any app shipping more than one localization. So on
/// the Apple TV this picker is the only way a household can run Plozz in a
/// different language from the device, which is exactly the case that matters:
/// one TV, several people, not all of whom read the same language.
///
/// Deliberately narrow in scope. Changing this changes **Plozz's own copy**. It
/// does not change:
///   * media titles, overviews or genres — those come from Jellyfin/Plex in
///     whatever language that server was configured with (a separate setting,
///     and a separate capability question per provider);
///   * preferred audio/subtitle track languages — a German UI does not imply
///     German audio, and conflating them would be wrong;
///   * dates, numbers and sort order — those follow the device REGION, which a
///     user reasonably keeps set to where they live.
public enum AppLanguage: Hashable, Sendable, Identifiable {
    /// Follow the device's language list. The default.
    case system
    /// A specific BCP-47 language tag the app actually ships (e.g. "es", "de").
    case explicit(String)

    public var id: String { storageValue }

    /// Stable value for `UserDefaults`. Empty string means "system", which keeps
    /// the stored representation a plain `String` and avoids an optional key.
    public var storageValue: String {
        switch self {
        case .system: return ""
        case let .explicit(code): return code
        }
    }

    public init(storageValue: String) {
        self = storageValue.isEmpty ? .system : .explicit(storageValue)
    }

    /// The locale to hand SwiftUI, or `nil` to leave the environment alone.
    public var locale: Locale? {
        switch self {
        case .system:
            return nil
        case let .explicit(code):
            // Keep the device's REGION and override only the language, so
            // choosing Spanish doesn't silently switch date and number formats to
            // Spain's. `Locale.current.region` is the user's actual region.
            var components = Locale.Components(identifier: code)
            if let region = Locale.current.region { components.region = region }
            return Locale(components: components)
        }
    }

    /// Every language the app can actually display, derived from what the bundle
    /// SHIPS rather than a hardcoded list — so adding a translation makes it
    /// appear in the picker with no code change (and, just as importantly, a
    /// language can never be offered that has no strings behind it).
    public static func available(in bundle: Bundle = .main) -> [AppLanguage] {
        let codes = bundle.localizations
            .filter { $0 != "Base" }
            .sorted { lhs, rhs in
                localizedName(for: lhs).localizedCaseInsensitiveCompare(localizedName(for: rhs)) == .orderedAscending
            }
        return [.system] + codes.map(AppLanguage.explicit)
    }

    /// The language's name written IN that language ("Español", not "Spanish") —
    /// the convention every platform picker uses, because someone looking for
    /// their own language recognises its endonym, not its English name.
    public var displayName: String {
        switch self {
        case .system:
            return String(localized: "language.system",
                          defaultValue: "System",
                          comment: "Language picker option meaning 'follow the device language'.")
        case let .explicit(code):
            return Self.localizedName(for: code)
        }
    }

    private static func localizedName(for code: String) -> String {
        let locale = Locale(identifier: code)
        let name = locale.localizedString(forIdentifier: code)
            ?? Locale.current.localizedString(forIdentifier: code)
            ?? code
        // Endonyms arrive lowercased in several languages ("español"); the picker
        // reads better capitalised, using that language's own casing rules.
        return name.capitalized(with: locale)
    }
}

// MARK: - Persistence

public protocol AppLanguageSettingsStoring: Sendable {
    func load() -> AppLanguage
    func save(_ language: AppLanguage)
}

/// Persists the chosen UI language. Scoped per profile like the other settings
/// stores, so one household member can read Plozz in Spanish while another keeps
/// English on the same Apple TV.
public final class AppLanguageSettingsStore: AppLanguageSettingsStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    /// - Parameter namespace: per-profile scope. `nil` (the default/primary
    ///   profile) uses the legacy un-suffixed key, matching every other store.
    public init(defaults: UserDefaults = .standard, namespace: String? = nil) {
        self.defaults = defaults
        self.key = SettingsKey.scoped("com.plozz.appLanguage", namespace: namespace)
    }

    public func load() -> AppLanguage {
        AppLanguage(storageValue: defaults.string(forKey: key) ?? "")
    }

    public func save(_ language: AppLanguage) {
        defaults.set(language.storageValue, forKey: key)
    }
}

/// Observable wrapper so a Settings screen can two-way bind and the choice can be
/// broadcast into the view tree.
@MainActor
@Observable
public final class AppLanguageSettingsModel {
    public var language: AppLanguage {
        didSet { store.save(language) }
    }

    private let store: AppLanguageSettingsStoring

    public init(store: AppLanguageSettingsStoring = AppLanguageSettingsStore()) {
        self.store = store
        self.language = store.load()
    }

    /// Locale to inject, or `nil` when following the system.
    public var locale: Locale? { language.locale }
}
