import Foundation

/// The hold-to-accelerate ramp extracted from `PlayerControls`' subtitle style
/// editor. Owns the same-direction streak state for one focused row so a
/// sustained left/right hold on the remote climbs the grid step 1→2→4→8 while
/// deliberate taps stay fine (1×). Any pause beyond `holdWindow`, a direction
/// flip, or a move to a different row restarts the streak at the fine step.
///
/// Pure value type (no SwiftUI, no clock of its own — `now` is injected) so the
/// ramp curve is directly unit-testable.
struct SubtitleStyleAccelerator {
    /// Idle window: a gap longer than this between same-direction moves resets
    /// the streak, so the next move is a fine 1× step again.
    static let holdWindow: TimeInterval = 0.32

    private var slot: Int?
    private var sign: Int = 0
    private var lastMove: Date = .distantPast
    private var streak: Int = 0

    init() {}

    /// Advances the streak for `slot` in `sign` direction at `now` and returns the
    /// grid magnitude to move. Mutates the accelerator's held state.
    mutating func magnitude(slot: Int, sign: Int, now: Date = Date()) -> Int {
        let held = self.slot == slot
            && self.sign == sign
            && now.timeIntervalSince(lastMove) < Self.holdWindow
        let newStreak = held ? streak + 1 : 0
        self.slot = slot
        self.sign = sign
        lastMove = now
        streak = newStreak
        return Self.rampMagnitude(newStreak)
    }

    /// Grid-index magnitude for a streak length: the first few repeats stay fine
    /// (1) so deliberate taps land exactly, then a sustained hold ramps up to
    /// cover large ranges quickly. On the 1% Position grid this reads as
    /// 1→2→4→8 % per repeat.
    static func rampMagnitude(_ streak: Int) -> Int {
        switch streak {
        case ..<3: return 1
        case ..<8: return 2
        case ..<16: return 4
        default: return 8
        }
    }
}
