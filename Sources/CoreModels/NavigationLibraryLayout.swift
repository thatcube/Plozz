import Foundation

/// A profile's **navigation library list**: which libraries appear in the app's
/// custom left navigation rail, and in what order.
///
/// Deliberately separate from ``HomeLibraryVisibility``: that answers "is this
/// library available at all / does it appear on Home", which is a *content*
/// decision the whole app honours. This answers "does this library get a slot in
/// the navigation chrome", which is a *layout* decision — a household may well
/// want a rarely-used library still browsable from Home while keeping the rail
/// short. A library that is disabled outright never reaches the rail regardless,
/// because the rail is fed the already-visible library set.
///
/// Per the "build for flexibility" mandate, layout is DATA: an explicit order plus
/// a hidden set, persisted per profile, resolved against the live library list via
/// the shared ``OrderedVisibilityList`` so a newly discovered library appears
/// (enabled, at the end) instead of silently vanishing.
public struct NavigationLibraryLayout: Codable, Equatable, Sendable {
    /// The reserved key of the synthetic **All Libraries** entry — a single
    /// combined browse over every visible library on every signed-in server. Not a
    /// real `AggregatedLibrary.key` (which is always `"accountID:libraryID"`, so
    /// the reserved form can never collide) but it participates in ordering and
    /// hiding exactly like one.
    public static let allLibrariesKey = "plozz.navigation.allLibraries"

    /// Navigation entry keys in the viewer's explicit order. Advisory: keys no
    /// longer present are ignored, and live keys missing from it are appended.
    public var order: [String]

    /// Entry keys the viewer has removed from the navigation rail. They stay fully
    /// browsable from Home — this only hides the rail slot.
    public var hiddenKeys: Set<String>

    public init(order: [String] = [], hiddenKeys: Set<String> = []) {
        self.order = order
        self.hiddenKeys = hiddenKeys
    }

    /// Every library in the rail, in discovery order, with All Libraries first —
    /// matching the standing direction that everything is on by default.
    public static let `default` = NavigationLibraryLayout()

    /// Whether an entry is shown in the navigation rail.
    public func isVisible(_ key: String) -> Bool {
        !hiddenKeys.contains(key)
    }

    /// Shows/hides one navigation entry.
    public mutating func setVisible(_ visible: Bool, for key: String) {
        if visible {
            hiddenKeys.remove(key)
        } else {
            hiddenKeys.insert(key)
        }
    }

    /// Resolves the persisted order + hidden set against the live entry keys.
    ///
    /// `available` must already be filtered to entries that exist right now (the
    /// All Libraries key plus every visible library key). The result's `enabled`
    /// section is exactly what the rail renders, top to bottom.
    public func sections(available: [String]) -> OrderedVisibilityList.Sections<String> {
        OrderedVisibilityList.resolving(available: available, order: order, hidden: hiddenKeys)
    }

    /// The rail's entries, in order.
    public func visibleKeys(available: [String]) -> [String] {
        sections(available: available).enabled
    }

    /// Replaces the layout from an edited pair of sections (the reorder control's
    /// output). Keys absent from `available` keep their persisted position/hidden
    /// state so a temporarily-offline server doesn't lose the viewer's arrangement.
    public mutating func apply(
        _ sections: OrderedVisibilityList.Sections<String>,
        available: [String]
    ) {
        let availableSet = Set(available)
        let edited = sections.combined
        // Splice the edited (live) keys back into the persisted order, keeping any
        // remembered key that isn't currently available exactly where it was.
        var result: [String] = []
        var editedIterator = edited.makeIterator()
        for key in order {
            if availableSet.contains(key) {
                if let next = editedIterator.next() { result.append(next) }
            } else {
                result.append(key)
            }
        }
        while let next = editedIterator.next() { result.append(next) }

        var seen: Set<String> = []
        order = result.filter { seen.insert($0).inserted }
        hiddenKeys = hiddenKeys.subtracting(availableSet).union(sections.disabled)
    }
}

/// Persists ``NavigationLibraryLayout`` across launches, scoped per profile.
public protocol NavigationLibraryLayoutStoring: Sendable {
    func load() -> NavigationLibraryLayout
    func save(_ layout: NavigationLibraryLayout)
}

public final class NavigationLibraryLayoutStore: NavigationLibraryLayoutStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    /// - Parameter namespace: per-profile scope. `nil` (the default/primary
    ///   profile) uses the un-suffixed key; other profiles pass their `Profile.id`
    ///   so each profile arranges its own navigation.
    public init(defaults: UserDefaults = .standard, namespace: String? = nil) {
        self.defaults = defaults
        self.key = SettingsKey.scoped("com.plozz.navigationLibraryLayout", namespace: namespace)
    }

    public func load() -> NavigationLibraryLayout {
        guard let data = defaults.data(forKey: key),
              let layout = try? JSONDecoder().decode(NavigationLibraryLayout.self, from: data) else {
            return .default
        }
        return layout
    }

    public func save(_ layout: NavigationLibraryLayout) {
        if let data = try? JSONEncoder().encode(layout) {
            defaults.set(data, forKey: key)
        }
    }
}
