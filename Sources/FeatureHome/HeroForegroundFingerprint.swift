import Foundation

/// A pure, `Equatable` snapshot-invalidation **fingerprint** for one hero slide's
/// non-interactive visual foreground (the description column the experimental
/// rasterizer bakes: logo/title, metadata, overview). Two renders are
/// interchangeable **iff** their fingerprints are equal; any change flips the
/// fingerprint so the cached raster is treated as stale and regenerated.
///
/// This is the contract that keeps a prepared artifact from ever showing wrong or
/// stale content: every input that changes what the description column *draws* is
/// a field here. What is deliberately **not** here (because the raster does not
/// own it) is anything the live overlay keeps: the selected-pill highlight,
/// focus, paging dots, and the pills themselves — those stay live so action
/// feedback is never stale.
///
/// ## Secret-safety
/// The fingerprint stores user-facing text (title/overview) to detect changes, so
/// it **must never be logged**. Perf markers log only ``hashValue`` — a
/// non-reversible `Int` — never the fields. `CustomStringConvertible` is
/// intentionally *not* conformed to, and callers must not interpolate a whole
/// fingerprint into a log line.
struct HeroForegroundFingerprint: Equatable, Hashable {
    /// Identity of the slide the snapshot belongs to. Guards against a snapshot
    /// keyed to one item ever being shown for another after a set swap.
    let itemID: String
    /// The title text as drawn (already spoiler-masked when masking applies), so a
    /// spoiler toggle regenerates.
    let title: String
    /// The overview text as drawn, or `nil` when the slide shows none (spoiler
    /// masking hides it) — so hiding/showing the overview regenerates.
    let overview: String?
    /// The joined metadata line (year · runtime · genres …) exactly as rendered.
    let metadata: String
    /// A stable identity for the rating badge chip, or `nil` when there is none.
    let ratingBadgeID: String?
    /// The slide's logo image source (`item.logoURL`), or `nil` when the slide has
    /// no provider logo. Synchronously knowable, so the view can reproduce this
    /// fingerprint at the transition frame. A changed URL regenerates the snapshot;
    /// the *arrival* of a not-yet-resolved logo is handled separately by the
    /// rasterizer's logo-upgrade pass (so this stays sync-computable and the "logo
    /// pops in" jump is still avoided) — see `HeroForegroundRasterizer`.
    let logoURLString: String?
    /// `true` in dark mode, `false` in light — the description's text/shadow tints
    /// are appearance-dependent, so a scheme change regenerates.
    let isDarkMode: Bool
    /// The measured action-row width (rounded to a whole point) the description
    /// caps its logo/title/overview to. `0` before the live pills are measured.
    /// Rounding avoids sub-pixel churn regenerating on every layout pass.
    let contentWidth: Int

    /// A non-reversible, secret-safe digest for logs/markers. Never log the
    /// fingerprint's fields directly — only this value.
    var loggableHash: Int { hashValue }
}
