#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// Applies the user's chosen UI language to everything inside it, and publishes
/// the settings model so a Settings screen can bind the SAME instance.
///
/// Wrap each app's root view in this once. Both shells use it so tvOS and iOS
/// cannot drift on how the override is applied.
///
/// ## Why environment values and not something more forceful
///
/// Injecting `\.locale` is the supported way to re-resolve SwiftUI text at
/// runtime, and `\.layoutDirection` mirrors explicit Arabic/Hebrew overrides.
/// They re-render live — no relaunch, which matters because the
/// alternative (writing `AppleLanguages` and restarting) is exactly the jarring
/// behaviour the system language switch already has.
///
/// It is honest about its limits, and those limits are worth knowing:
///   * It does **not** change `Locale.current`. Any non-view code that formats or
///     compares text must be handed a locale explicitly rather than reading the
///     process-wide one.
///   * It does not reach system-drawn UI — AVKit's player chrome and permission
///     prompts follow the device language. Top Shelf titles are different: the
///     app resolves those before writing its cross-process snapshot.
@MainActor
public struct AppLanguageScope<Content: View>: View {
    /// The locale this view already sits in — the device's, unless something
    /// above us has overridden it.
    @Environment(\.locale) private var inheritedLocale
    @Environment(\.layoutDirection) private var inheritedLayoutDirection
    @State private var model: AppLanguageSettingsModel
    private let content: Content

    public init(
        model: AppLanguageSettingsModel? = nil,
        @ViewBuilder content: () -> Content
    ) {
        // The model reads UserDefaults on init and is @MainActor, so it can't be
        // a default argument (those are evaluated in a nonisolated context).
        _model = State(initialValue: model ?? AppLanguageSettingsModel())
        self.content = content()
    }

    public var body: some View {
        content
            .environment(model)
            // For `.system` we re-inject what we INHERITED rather than a captured
            // `Locale.current`. The comment here used to claim it left the
            // environment untouched while doing exactly the opposite — freezing
            // the language at launch, so a change made in Settings.app would not
            // be picked up.
            .environment(\.locale, model.locale ?? inheritedLocale)
            .environment(
                \.layoutDirection,
                model.language.isRightToLeft.map {
                    $0 ? LayoutDirection.rightToLeft : .leftToRight
                } ?? inheritedLayoutDirection
            )
            // Deliberately NO `.id(model.language)`. Re-identifying the root would
            // guarantee every string re-resolves, but it tears down and rebuilds
            // the whole tree — losing scroll position and tvOS focus on every
            // change. Measured on device: the environment change alone re-renders
            // the UI correctly, because nothing resolves a resource eagerly (the
            // l10n guard's `eager-localization` rule is what keeps that true).
    }
}
#endif
