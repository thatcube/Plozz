import CoreNetworking
import Foundation
import Observation
import SwiftUI

/// Tracks how many detail pages are currently on a navigation stack, so a page
/// can tell whether it is the one on top or has a child pushed over it.
///
/// A `NavigationStack` does **not** fire `onDisappear` on the view a push covers,
/// so a page cannot otherwise notice it has been covered. The pushed page's own
/// `onAppear`/`onDisappear` *do* fire, which makes them the reliable signal.
///
/// This matters because tvOS re-establishes focus by geometry when the stack
/// changes, landing on the topmost focusable control — the hero Play button. The
/// series page treats Play gaining focus as "the user pressed up out of the
/// episode browser" and restores the hero, which collapses the browser and hides
/// the cast with it. Verified on device: that happens as the child is *pushed*,
/// not when it is popped. Knowing a child is on top lets the page ignore focus
/// changes it did not cause, rather than trying to undo them afterwards.
@MainActor
@Observable
public final class DetailStackDepth {
    /// The number of detail pages currently on the stack.
    public private(set) var depth = 0

    public init() {}

    public func pageAppeared() {
        depth += 1
        note("appeared")
    }

    public func pageDismissed() {
        depth = max(0, depth - 1)
        note("dismissed")
    }

    // MARK: - Runaway detection (temporary)
    //
    // `depth` is mutated from `onAppear` and READ during `ItemDetailView`'s body
    // (`isShed`), so if a page's identity churns, `onAppear` runs again and the
    // counter climbs with no matching `onDisappear` — a loop that feeds itself
    // and never settles. A device capture showed ItemDetailView rebuilding ~1,289
    // times against 343 parent renders, and the app hanging indefinitely rather
    // than recovering, which is the shape that would produce.
    //
    // RATE-LIMITED on purpose. The obvious version — log every transition — is
    // exactly the mistake that made an earlier capture worse: at storm frequency,
    // a synchronous write per event is itself enough to saturate the main thread.
    // This emits at most once a second, plus once when the depth first passes a
    // level no real navigation reaches.

    /// Total transitions seen, so a rate-limited line can still report the true
    /// rate rather than only the ones that got logged.
    private var transitions = 0
    private var lastNote = ContinuousClock.now
    private var warnedRunaway = false

    private func note(_ event: String) {  // l10n:content — developer-facing diagnostic
        transitions += 1
        // A real stack is a handful of pages deep. Anything past this is the
        // counter running away, and it is worth one line the moment it happens.
        if depth > 8, !warnedRunaway {
            warnedRunaway = true
            PlozzLog.boot("DetailStackDepth RUNAWAY depth=\(depth) transitions=\(transitions)")
        }
        let now = ContinuousClock.now
        guard lastNote.duration(to: now) >= .seconds(1) else { return }
        lastNote = now
        PlozzLog.boot(
            "DetailStackDepth \(event) depth=\(depth) transitions=\(transitions)"
        )
    }
}
