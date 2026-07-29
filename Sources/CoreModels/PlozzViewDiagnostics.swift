import Foundation

/// Opt-in, zero-cost-when-off instrumentation for SwiftUI re-render churn.
///
/// A Time Profiler trace of the tvOS detail screen came back ~60% unsymbolicated,
/// and what *was* symbolicated was almost entirely AttributeGraph internals
/// (`AG::Subgraph::update`, `AG::Graph::propagate_dirty`). That tells you the
/// tree is being invalidated too often, but not by whom — which is the only
/// question worth answering.
///
/// `Self._printChanges()` answers it directly: SwiftUI names the view being
/// re-evaluated AND the property that dirtied it (`@self`, `@identity`, or the
/// specific stored property). Wire it into a body with:
///
/// ```swift
/// var body: some View {
///     let _ = plozzTraceBodyChanges { Self._printChanges() }
///     …
/// }
/// ```
///
/// and run the app with `PLOZZ_TRACE_BODIES=1` to stream it off the device.
public enum PlozzViewDiagnostics {
    /// Checked once, so the guard in every instrumented body is a static Bool
    /// read rather than an environment lookup.
    public static let tracesViewBodies: Bool =
        ProcessInfo.processInfo.environment["PLOZZ_TRACE_BODIES"] == "1"
}

/// Runs `printChanges` only when body tracing is enabled.
///
/// Takes a closure because `_printChanges()` is a static method on the concrete
/// `View` type, so it can only be called from inside that view's own body.
@inline(__always)
public func plozzTraceBodyChanges(_ printChanges: () -> Void) {
    guard PlozzViewDiagnostics.tracesViewBodies else { return }
    printChanges()
}
