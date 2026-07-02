import Foundation

/// One "here's what Plozz can do" card shown during first-run onboarding (and
/// re-viewable from Settings). Deliberately a **plain, ordered value type** so the
/// welcome experience is data-driven: the set below can be reordered, edited,
/// added to, or A/B'd centrally without touching any SwiftUI `body`. Content is
/// **provider-neutral** — it must read true whether the household runs Plex,
/// Jellyfin, or both (the dual-provider mandate).
///
/// `symbol` is an SF Symbol name (like `Profile.avatarSymbol`) so `CoreModels`
/// stays Foundation-only and the UI layer resolves the glyph. No image assets.
public struct OnboardingHighlight: Identifiable, Hashable, Sendable {
    /// Stable identifier — also the ordering/dedup key and a handle for future
    /// per-profile "hide this card" customization without a rewrite.
    public let id: String
    /// SF Symbol name rendered as the card's icon.
    public let symbol: String
    /// Short, benefit-led headline.
    public let title: String
    /// One or two sentences expanding the headline. Where useful, points the
    /// user at the Settings section that unlocks the feature.
    public let message: String

    public init(id: String, symbol: String, title: String, message: String) {
        self.id = id
        self.symbol = symbol
        self.title = title
        self.message = message
    }
}

public extension OnboardingHighlight {
    /// The ordered default set of features a new user should know about when
    /// getting set up. Ordered by "what makes Plozz different first": the
    /// dual-provider unified library, then household profiles, then the
    /// integrations / playback / customization that reward exploring Settings.
    ///
    /// This array is the single source of truth for the welcome screen and the
    /// Settings "What Plozz Can Do" page. To change what new users see, edit
    /// here — no UI changes required.
    static let defaultHighlights: [OnboardingHighlight] = [
        OnboardingHighlight(
            id: "unified-servers",
            symbol: "square.stack.3d.up.fill",
            title: "Plex and Jellyfin, together",
            message: "Sign in to as many Plex and Jellyfin servers as you like. Your Home and Search merge everything into one place — add more any time from Settings."
        ),
        OnboardingHighlight(
            id: "profiles",
            symbol: "person.2.fill",
            title: "A profile for everyone",
            message: "Give each person in your household their own space — separate Continue Watching, settings, and history. Set up who's watching in Settings ▸ Profiles."
        ),
        OnboardingHighlight(
            id: "trackers",
            symbol: "arrow.triangle.2.circlepath",
            title: "Keep your watching in sync",
            message: "Connect Trakt, Simkl, AniList, MyAnimeList, or Last.fm to scrobble what you play — and keep watch state in sync across all your servers."
        ),
        OnboardingHighlight(
            id: "playback",
            symbol: "film.stack.fill",
            title: "Cinema-grade playback",
            message: "Dolby Vision and Dolby Atmos pass through untouched, with Match Content frame-rate and dynamic-range switching for a true home-theater picture."
        ),
        OnboardingHighlight(
            id: "captions",
            symbol: "captions.bubble.fill",
            title: "Subtitles and audio, your way",
            message: "Style captions exactly how you like them, and set default audio and subtitle languages per content type in Settings ▸ Playback."
        ),
        OnboardingHighlight(
            id: "personalize",
            symbol: "paintbrush.fill",
            title: "Make it yours",
            message: "Themes, liquid-glass transparency, Night Shift, and spoiler protection are all a few clicks away in Settings ▸ Appearance."
        ),
        OnboardingHighlight(
            id: "search",
            symbol: "magnifyingglass",
            title: "Find anything, fast",
            message: "Search every connected server at once from the Search tab — one query, all your libraries."
        ),
        OnboardingHighlight(
            id: "privacy",
            symbol: "lock.fill",
            title: "Private by design",
            message: "Plozz talks only to your servers and the services you choose to connect. Your sign-in tokens stay in the Apple TV Keychain — never in the cloud."
        ),
    ]
}

/// Persistence for the one-time first-run welcome. Held here so every site that
/// reads/writes the flag — `RootView` (gates the welcome) and the Settings
/// re-view entry — shares one key and default instead of duplicating a literal.
///
/// **App-wide, NOT per-profile.** "Has this Apple TV been welcomed" is a
/// device/household first-run fact, not a personal content preference, so it uses
/// a plain un-namespaced key and is intentionally excluded from
/// `AppState.rebuildSettingsModels()` (same rationale as `TransparencyPreference`).
/// See AGENTS.local.md — "Per-profile vs app-wide settings".
public enum OnboardingWelcome {
    /// AppStorage/UserDefaults key for whether the welcome has been shown.
    public static let storageKey = "hasSeenWelcome"
    /// A fresh install has not seen the welcome yet.
    public static let defaultSeen = false
}
