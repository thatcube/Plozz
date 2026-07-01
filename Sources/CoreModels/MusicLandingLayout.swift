import Foundation
import Observation

/// One section of the Music landing page. The page is composed from an ordered,
/// toggleable list of these rather than a hardcoded `body`, so the layout can be
/// reordered, hidden/shown, or made user-customizable later as a *value* change
/// instead of a view rewrite.
public enum MusicLandingSection: String, Codable, Hashable, CaseIterable, Sendable {
    case recentlyPlayed
    case browse
    case albums
    case artists
    case playlists
}

/// The Music landing page composition: an ordered list of sections, each with a
/// visibility flag. Presentation only — it is **not** part of any data cache key.
public struct MusicLandingLayout: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable {
        public var section: MusicLandingSection
        public var isVisible: Bool

        public init(section: MusicLandingSection, isVisible: Bool = true) {
            self.section = section
            self.isVisible = isVisible
        }
    }

    public var items: [Item]

    public init(items: [Item]) {
        self.items = items
    }

    /// Shipped default order: Browse → Recently Played → Playlists → Albums → Artists.
    public static let `default` = MusicLandingLayout(items: [
        Item(section: .browse),
        Item(section: .recentlyPlayed),
        Item(section: .playlists),
        Item(section: .albums),
        Item(section: .artists)
    ])

    /// The sections to render, in order, filtered to the visible ones. Any
    /// section type absent from a persisted (older) layout is appended in its
    /// default position so introducing a new section stays forward-compatible.
    public var visibleSections: [MusicLandingSection] {
        let known = Set(items.map(\.section))
        let appended = MusicLandingLayout.default.items.filter { !known.contains($0.section) }
        return (items + appended).filter(\.isVisible).map(\.section)
    }
}

/// Persists `MusicLandingLayout` per-profile.
public protocol MusicLandingLayoutStoring: Sendable {
    func load() -> MusicLandingLayout
    func save(_ layout: MusicLandingLayout)
}

public final class MusicLandingLayoutStore: MusicLandingLayoutStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, namespace: String? = nil) {
        self.defaults = defaults
        self.key = SettingsKey.scoped("com.plozz.musicLandingLayout", namespace: namespace)
    }

    public func load() -> MusicLandingLayout {
        guard let data = defaults.data(forKey: key),
              let layout = try? JSONDecoder().decode(MusicLandingLayout.self, from: data) else {
            return .default
        }
        return layout
    }

    public func save(_ layout: MusicLandingLayout) {
        if let data = try? JSONEncoder().encode(layout) {
            defaults.set(data, forKey: key)
        }
    }
}

/// A no-op store for tests/previews that must not touch `UserDefaults`.
public final class EphemeralMusicLandingLayoutStore: MusicLandingLayoutStoring, @unchecked Sendable {
    private var layout: MusicLandingLayout
    public init(layout: MusicLandingLayout = .default) { self.layout = layout }
    public func load() -> MusicLandingLayout { layout }
    public func save(_ layout: MusicLandingLayout) { self.layout = layout }
}

/// Observable wrapper so a future Settings surface can two-way bind section
/// order/visibility and have the choice persisted. No customization UI ships
/// this pass — the model exists so the layout is data, not a hardcoded view.
@MainActor
@Observable
public final class MusicLandingLayoutModel {
    public private(set) var layout: MusicLandingLayout

    private let store: MusicLandingLayoutStoring

    public init(store: MusicLandingLayoutStoring = MusicLandingLayoutStore()) {
        self.store = store
        self.layout = store.load()
    }

    public func update(_ layout: MusicLandingLayout) {
        self.layout = layout
        store.save(layout)
    }
}
