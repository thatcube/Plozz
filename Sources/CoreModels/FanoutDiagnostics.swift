import Foundation
#if canImport(OSLog)
import OSLog
#endif

/// On-device **watch fan-out** telemetry. Makes the entire cross-server convergence
/// chain visible in the device console so a broken link can be pinpointed on real
/// multi-server hardware (which can't be reproduced locally).
///
/// Every line is tagged `PLZXFAN` (a deliberately unique token — Apple's own push
/// stack also logs the word "Fanout", so a generic tag collides) and emitted under
/// subsystem `com.plozz.app`, category `fanout`. Search `PLZXFAN` in Console.app or
/// `log stream --predicate 'eventMessage CONTAINS "PLZXFAN"'`.
///
/// Design constraints (must hold):
///  - **Never delay or alter the durable watch write.** Emitting is a fire-and-
///    forget `os_log`; the formatting is cheap string building. Nothing here ever
///    blocks, throws, or feeds back into the convergence path.
///  - **Secret-safe.** Only account ids, item ids, titles, provider kinds and
///    external catalogue ids are logged — never tokens/PINs/auth headers.
///  - **Toggleable.** Gated by ``isEnabled`` (default on for this diagnostics
///    build) so it can be silenced without ripping the seams out.
///  - **Linux-safe.** `OSLog` is guarded so the pure logic modules still compile on
///    non-Apple toolchains (CI runs `swift test` on Linux). The string builders are
///    pure and unit-testable everywhere.
public enum FanoutDiagnostics {
    /// Thread-safe on/off gate. Default **on** for this diagnostics branch so the
    /// maintainer can stream telemetry without toggling anything; flip via
    /// ``setEnabled(_:)`` (e.g. from a Settings switch) to silence it.
    private static let gate = Gate()

    /// Whether fan-out telemetry is currently emitted.
    public static var isEnabled: Bool { gate.isEnabled }

    /// Enables/disables emission at runtime (e.g. mirrors a diagnostics setting).
    public static func setEnabled(_ enabled: Bool) { gate.setEnabled(enabled) }

    #if canImport(OSLog)
    private static let logger = Logger(subsystem: "com.plozz.app", category: "fanout")
    #endif

    /// When the process is launched with `PLZXFAN_STDOUT=1` in its environment,
    /// each telemetry line is ALSO written to stdout. `os_log` (above) only reaches
    /// the unified logging system, which a remote driver can't read on this macOS
    /// toolchain; stdout, however, is forwarded by `devicectl device process launch
    /// --console`. This lets the maintainer's agent stream telemetry off the Apple TV
    /// live instead of copy-pasting Console.app. Opt-in (read once at startup) so
    /// normal runs and unit tests stay silent.
    private static let mirrorsStandardOut: Bool =
        ProcessInfo.processInfo.environment["PLZXFAN_STDOUT"] == "1"

    /// Emits one already-formatted telemetry line (the `PLZXFAN ` prefix is added).
    /// No-op when disabled. Public so the AppShell seams (stop handler, applier) can
    /// emit the lines they alone have the data for.
    public static func emit(_ line: String) {
        guard gate.isEnabled else { return }
        #if canImport(OSLog)
        // `.notice` (OSLogType.default) so Console.app shows these WITHOUT the
        // "Include Info Messages" toggle, and so they persist to the log store
        // (retrievable later via `log show` / sysdiagnose). Info/debug levels are
        // hidden by default and were invisible on device.
        logger.notice("PLZXFAN \(line, privacy: .public)")
        #endif
        if mirrorsStandardOut {
            // Unbuffered write so `devicectl --console` sees each line immediately.
            try? FileHandle.standardOutput.write(contentsOf: Data(("PLZXFAN " + line + "\n").utf8))
        }
    }

    // MARK: - Pure line builders (testable, no OSLog dependency)

    /// (a) Identity-index state: how many identities are indexed and how many span
    /// more than one account (a cross-server union). `crossServer == 0` ⇒ the index
    /// never warmed a union ⇒ nothing can fan out (the H1 bug class).
    public static func indexStateLine(_ snapshot: IdentityIndexSnapshot, phase: String) -> String {
        let accountIDs = snapshot.indexedAccountIDs.sorted()
        return "\(phase): identities=\(snapshot.identityCount) "
            + "crossServer=\(snapshot.crossServerIdentityCount) "
            + "accounts=\(accountIDs.count) accountIDs=\(accountIDs)"
    }

    /// (b)+(c) The stop event: the played item's resolved identity, the index union
    /// found for it, and the mutation's final target set. `union`/`targets` of 1 ⇒
    /// origin-only ⇒ no fan-out for this title.
    public static func stopLine(
        title: String,
        kind: MediaItemKind,
        itemID: String,
        originAccountID: String?,
        identities: [MediaIdentity],
        indexUnion: [MediaSourceRef],
        mutationTargets: [WatchMutationTarget]?,
        played: Bool?,
        resumePosition: TimeInterval?,
        watchedPercent: Double,
        phase: String = "stop"
    ) -> String {
        let identityDesc = identities.isEmpty ? "none" : "[\(identities.map(describe).joined(separator: ", "))]"
        let unionDesc = describeSources(indexUnion)
        let mutationDesc: String
        if let targets = mutationTargets {
            mutationDesc = "targets=\(targets.count) \(describeTargets(targets)) "
                + "played=\(played.map(String.init(describing:)) ?? "nil") "
                + "resume=\(resumePosition.map { String(format: "%.0f", $0) } ?? "nil")"
        } else {
            mutationDesc = "mutation=nil (nothing to converge — no targets or barely started)"
        }
        return "\(phase): item=\"\(title)\" kind=\(kind) id=\(itemID) origin=\(originAccountID ?? "nil") "
            + "watched=\(String(format: "%.1f", watchedPercent))% "
            + "identity=\(identityDesc) "
            + "indexUnion=\(indexUnion.count) \(unionDesc) | \(mutationDesc)"
    }

    /// (d) Drain header for one mutation, before its targets are written.
    public static func drainHeaderLine(
        canonicalMediaID: String,
        played: Bool?,
        resumePosition: TimeInterval?,
        clearResume: Bool,
        targets: [WatchMutationTarget],
        expansionPending: Bool
    ) -> String {
        "drain: canonical=\(canonicalMediaID) "
            + "played=\(played.map(String.init(describing:)) ?? "nil") "
            + "resume=\(resumePosition.map { String(format: "%.0f", $0) } ?? "nil") "
            + "clearResume=\(clearResume) targets=\(targets.count) \(describeTargets(targets)) "
            + "expansionPending=\(expansionPending)"
    }

    /// (d) Per-target write outcome. `outcome` is a short verb phrase such as
    /// `setPlayed=OK setResume=OK`, `deferred(live)`, or `setPlayed=THROW(...)`.
    public static func drainTargetLine(_ target: WatchMutationTarget, outcome: String) -> String {
        "drain.target acct=\(target.accountID) item=\(target.itemID) "
            + "kind=\(target.providerKind?.rawValue ?? "?") -> \(outcome)"
    }

    /// (d) Drain summary after one mutation pass.
    public static func drainDoneLine(
        canonicalMediaID: String,
        remainingTargets: Int,
        fullyApplied: Bool,
        traktPending: Bool
    ) -> String {
        "drain.done canonical=\(canonicalMediaID) remainingTargets=\(remainingTargets) "
            + "fullyApplied=\(fullyApplied) traktPending=\(traktPending)"
    }

    // MARK: - Formatting helpers

    static func describe(_ identity: MediaIdentity) -> String {
        switch identity {
        case let .external(source, value): return "\(source):\(value)"
        case let .title(normalizedTitle, year, kind):
            return "title:\(normalizedTitle):\(year.map(String.init) ?? "?"):\(kind)"
        case let .sameItemID(id): return "itemID:\(id)"
        }
    }

    static func describeSources(_ sources: [MediaSourceRef]) -> String {
        guard !sources.isEmpty else { return "[]" }
        return "[" + sources.map { "\($0.accountID):\($0.itemID):\($0.providerKind?.rawValue ?? "?")" }
            .joined(separator: ", ") + "]"
    }

    static func describeTargets(_ targets: [WatchMutationTarget]) -> String {
        guard !targets.isEmpty else { return "[]" }
        return "[" + targets.map { "\($0.accountID):\($0.itemID):\($0.providerKind?.rawValue ?? "?")" }
            .joined(separator: ", ") + "]"
    }

    /// A thread-safe boolean holder (the module targets strict concurrency on Swift
    /// 5.9, so a plain mutable static isn't `Sendable`).
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var enabled = true
        var isEnabled: Bool { lock.lock(); defer { lock.unlock() }; return enabled }
        func setEnabled(_ value: Bool) { lock.lock(); enabled = value; lock.unlock() }
    }
}
