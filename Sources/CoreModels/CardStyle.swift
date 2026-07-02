import Foundation

/// How media cards (posters, landscape thumbnails) are presented (pure data model).
///
/// A per-profile display preference that sits alongside `UIDensity`: it doesn't
/// change *how big* cards are, only whether they wear the liquid-glass card
/// frame. Persisted **per profile** (each profile keeps its own style) like
/// `UIDensity` / `AppTheme`; the concrete rendering lives in `CoreUI`
/// (`PosterCardView`), so this stays Foundation-only and the Settings screen can
/// edit it without importing SwiftUI.
public enum CardStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    /// The default: artwork nested inside a liquid-glass card surface, with a
    /// uniform inset border and the caption sitting on the glass.
    case framed
    /// No card background at all — just the artwork and its sub-text. The image
    /// fills the whole slot (so it reads larger), is rounded at the card's outer
    /// radius, and gains the same focus glass halo the artist/cast tiles use.
    case borderless

    public var id: String { rawValue }

    /// Short, user-facing option label for the Settings picker.
    public var displayName: String {
        switch self {
        case .framed: return "Cards"
        case .borderless: return "Posters"
        }
    }

    /// Tiny line shown beneath the picker, updated live as focus moves. Kept
    /// deliberately minimal — a few words is enough to disambiguate the two looks.
    public var detail: String {
        switch self {
        case .framed: return "Framed in a card."
        case .borderless: return "Just the artwork."
        }
    }

    public static let `default`: CardStyle = .framed
}
