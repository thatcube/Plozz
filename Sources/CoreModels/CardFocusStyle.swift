import Foundation

/// How a media card shows that it holds focus (pure data model).
///
/// A per-profile display preference that sits alongside `CardStyle`: it doesn't
/// change what a card looks like at rest, only what happens when focus lands on
/// it. Persisted **per profile** like `CardStyle` / `UIDensity`; the concrete
/// rendering lives in `CoreUI` (`plozzCardFocusLift`, `plozzFocusHalo`), so this
/// stays Foundation-only and the Settings screen can edit it without importing
/// SwiftUI.
///
/// Only the tvOS shell reads it — iOS has no focus engine — but it lives here
/// with every other card preference so the two shells share one settings model.
public enum CardFocusStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    /// The default: a focused card lights its glass surface, and an artwork-only
    /// card blooms a glass halo around its edge.
    case outlined
    /// tvOS's native treatment instead: no outline or halo at all. The card
    /// simply grows — far enough that it still covers the ground the outline
    /// used to (see `PlozzTheme.Metrics.highlightFocusScale`) — catches a
    /// specular sheen as it takes focus, and settles gently back when it loses
    /// it.
    case highlight

    public var id: String { rawValue }

    /// Whether this style draws a focus outline (a glass frame or halo) at all.
    /// The single question every card asks, so no view has to switch on the case.
    public var drawsFocusOutline: Bool { self == .outlined }

    /// Short, user-facing option label for the Settings picker.
    public var displayName: LocalizedStringResource {
        switch self {
        case .outlined:
            return LocalizedStringResource(
                "cardFocusStyle.outlined",
                defaultValue: "Outline",
                comment: "Card focus-style option in Settings > Appearance: the focused card is framed by a glass outline."
            )
        case .highlight:
            return LocalizedStringResource(
                "cardFocusStyle.highlight",
                defaultValue: "Highlight",
                comment: "Card focus-style option in Settings > Appearance: the focused card grows and catches the light instead of being outlined."
            )
        }
    }

    /// Tiny line shown beneath the picker, updated live as focus moves.
    public var detail: LocalizedStringResource {
        switch self {
        case .outlined:
            return LocalizedStringResource(
                "cardFocusStyle.detail.outlined",
                defaultValue: "The focused card is outlined in glass.",
                comment: "One-line explanation shown under the card focus-style picker."
            )
        case .highlight:
            return LocalizedStringResource(
                "cardFocusStyle.detail.highlight",
                defaultValue: "No outline — the card grows and catches the light.",
                comment: "One-line explanation shown under the card focus-style picker."
            )
        }
    }

    public static let `default`: CardFocusStyle = .outlined
}
