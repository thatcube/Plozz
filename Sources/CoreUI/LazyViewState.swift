#if canImport(SwiftUI)
import SwiftUI

/// Holds a value that must be built **once per view identity**, not once per
/// `body` evaluation.
///
/// `@State`'s `initialValue:` is only *used* the first time a view is installed
/// — but the expression producing it is evaluated on **every** `body` pass, and
/// every later result is thrown away. For a cheap value that is harmless. For a
/// view model that allocates, captures a dozen escaping closures and reads a
/// cached snapshot off disk, it is pure waste, paid at exactly the moments the
/// main thread is busiest.
///
/// Measured on the Apple TV before this existed: `HomeTab.body` re-ran roughly
/// 14×/second while a media share was scanning, and each pass built a fresh
/// `HomeViewModel` — 824 of them in a single minute, all but the first
/// discarded. The device reached `thermal=serious` and the UI froze.
///
/// Usage — declare the box as `@State` so it shares the view's lifetime, then
/// build through it. The closure runs only on the first pass:
///
/// ```swift
/// @State private var model = LazyViewState<HomeViewModel>()
///
/// var body: some View {
///     HomeView(viewModel: model.value { HomeViewModel(…) })
/// }
/// ```
///
/// Identity still governs lifetime: when the hosting view's identity changes
/// (an `.id(…)` on a profile/account scope key, say), SwiftUI discards the
/// `@State` and the next `value(_:)` builds a fresh one — the same moment a
/// `@State`-held model would have been recreated. So this changes *how often*
/// the value is built, never *when* it is replaced.
@MainActor
public final class LazyViewState<Value> {
    private var stored: Value?
    private var storedKey: AnyHashable?

    public init() {}

    /// The held value, building it with `make` on first use only.
    public func value(_ make: () -> Value) -> Value {
        value(forKey: 0, make)
    }

    /// The held value, rebuilt only when `key` changes.
    ///
    /// Use this when the box is owned **above** the view that consumes it. Held
    /// as `@State` on the consuming view, SwiftUI's own identity decides the
    /// lifetime — but that is exactly what proved unreliable here: a `TabView`
    /// re-hosting its tabs discarded the Home tab's `@State` and restarted a
    /// four-account load that was already seconds in, and it did so for whatever
    /// unrelated observable happened to change first (music availability one
    /// launch, theme-music settings the next). Hoisting the box to a stable
    /// owner and giving it an explicit key makes the lifetime say what it means:
    /// rebuild when the account/profile scope changes, and at no other time.
    public func value(forKey key: some Hashable, _ make: () -> Value) -> Value {
        let key = AnyHashable(key)
        if let stored, storedKey == key { return stored }
        let built = make()
        stored = built
        storedKey = key
        return built
    }
}

/// A tiny keyed cache for values that must survive `body` re-evaluation but come
/// in more than one flavour at a time — a navigation stack's pages, typically.
///
/// ``LazyViewState`` holds a single value, which is wrong for a `NavigationStack`:
/// while page B is on top, the destination closure for page A still re-runs, so a
/// one-slot box would rebuild A and B alternately and be worse than no cache at
/// all. This keeps the most recent few keys instead.
///
/// The problem it solves is the one in docs/performance-debugging.md §5: a view
/// model built inside a `navigationDestination` closure is rebuilt on every render
/// pass and thrown away, because the destination view keeps only the first in
/// `@State`. Measured on the Apple TV: opening three detail pages constructed
/// **13** `ItemDetailViewModel`s, each of which also resolves the item's
/// cross-server sources.
@MainActor
public final class KeyedViewStateCache<Key: Hashable, Value> {
    private var storage: [Key: Value] = [:]
    private var order: [Key] = []
    private let capacity: Int

    /// - Parameter capacity: how many keys to retain. The default comfortably
    ///   covers a detail stack (series → season → episode) plus the page you
    ///   came from, which is what stops the alternating-rebuild thrash.
    public init(capacity: Int = 4) {
        self.capacity = max(1, capacity)
    }

    /// The value for `key`, building it with `make` only when absent.
    public func value(forKey key: Key, _ make: () -> Value) -> Value {
        if let existing = storage[key] {
            return existing
        }
        let built = make()
        storage[key] = built
        order.append(key)
        while order.count > capacity {
            storage.removeValue(forKey: order.removeFirst())
        }
        return built
    }
}
#endif
