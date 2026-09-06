import Foundation

/// N-second continuous condition gate.
///
/// Accumulates time only while `isConditionMet == true`.
/// When the condition becomes false, the accumulator resets immediately.
/// When the accumulated time reaches `requiredDuration`, `tick` returns `true` once.
///
/// Design ref: design.md "TimedConditionGate" section.
struct TimedConditionGate {
    var requiredDuration: TimeInterval
    private var accumulated: TimeInterval = 0
    private var isFired: Bool = false

    init(requiredDuration: TimeInterval) {
        self.requiredDuration = requiredDuration
    }

    /// Call each frame with the current condition state and timestamp.
    /// - Returns: `true` once when the accumulated time first reaches `requiredDuration`.
    mutating func tick(isConditionMet: Bool, now: TimeInterval) -> Bool {
        if isConditionMet {
            if !isFired {
                accumulated += 1.0 / 60.0  // Assume ~60fps frame rate
                if accumulated >= requiredDuration {
                    isFired = true
                    return true
                }
            }
        } else {
            accumulated = 0
            isFired = false
        }
        return false
    }

    mutating func reset() {
        accumulated = 0
        isFired = false
    }
}