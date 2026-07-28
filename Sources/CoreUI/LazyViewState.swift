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

    public init() {}

    /// The held value, building it with `make` on first use only.
    public func value(_ make: () -> Value) -> Value {
        if let stored { return stored }
        let built = make()
        stored = built
        return built
    }
}
#endif
