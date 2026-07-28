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
            var components = Locale.Components(identifier: code)
            // Setting `.region` overrides FORMATTING only (it produces `@rg=`), and
            // leaves the tag's own region on `languageComponents` untouched. So
            // "pt-BR" for a US user yields `pt_BR@rg=uszzzz`: Brazilian Portuguese
            // text, US dates and numbers — which is what we want. Worth stating
            // because `Locale.region` and `Locale.language.region` look
            // interchangeable and are not; only the latter selects the `.lproj`.
            if let region = Locale.current.region { components.region = region }
            return Locale(components: components)
        }
    }

    /// Languages this build is prepared to OFFER, in the order shown.
    ///
    /// Deliberately an explicit list rather than "whatever `.lproj` folders exist".
    /// A bundled localization only means *some* strings were translated — Spanish
    /// sat at ~8% while its folder was present, and offering that would show a
    /// mostly-English UI to someone who asked for Spanish. Readiness is a release
    /// decision, so it is stated here and reviewed when a language actually ships.
    ///
    /// Adding a language: translate it, check it against the pseudolocalization
    /// pass, then add its tag here.
    public static let releaseReady: [String] = []

    /// Every language the picker should show: `.system` plus the release-ready
    /// tags that are actually present in the bundle. The bundle check means a
    /// mis-typed tag can never produce an option with nothing behind it.
    public static func available(in bundle: Bundle = .main) -> [AppLanguage] {
        let shipped = Set(bundle.localizations)
        let offered = releaseReady
            .filter(shipped.contains)
            .sorted { lhs, rhs in
                localizedName(for: lhs).localizedCaseInsensitiveCompare(localizedName(for: rhs)) == .orderedAscending
            }
        return [.system] + offered.map(AppLanguage.explicit)
    }

    /// The endonym for a specific language. `nil` for `.system`, whose label is
    /// app copy rather than a language name — see `systemOptionTitle`.
    ///
    /// Split in two because resolving the "System" label here required
    /// `String(localized:)`, which freezes it at the process locale and ignores
    /// the locale injected by AppLanguageScope. That is precisely the eager
    /// resolution the guard forbids elsewhere.
    public var endonym: String? {
        switch self {
        case .system: return nil
        case let .explicit(code): return Self.localizedName(for: code)
        }
    }

    /// Label for the "follow the device" option — real copy, so a resource.
    public static let systemOptionTitle = LocalizedStringResource(
        "language.system",
        defaultValue: "System",
        comment: "Language picker option meaning 'follow the device language'."
    )

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
