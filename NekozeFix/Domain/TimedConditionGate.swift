import Foundation

/// N-second continuous condition gate.
///
/// Accumulates time only while `isConditionMet == true`.
/// When the condition becomes false, the accumulator resets immediately.
/// When the accumulated time reaches `requiredDuration`, `tick` returns `true` once.
///
/// Design ref: design.md "TimedConditionGate" section.
struct TimedConditionGate: Equatable {
    var requiredDuration: TimeInterval
    var accumulated: TimeInterval = 0
    var isFired: Bool = false

    init(requiredDuration: TimeInterval) {
        self.requiredDuration = requiredDuration
    }

    /// Call each frame with the current condition state and elapsed time delta.
    /// - Parameters:
    ///   - isConditionMet: whether the gate condition is currently satisfied
    ///   - deltaTime: time elapsed since the last tick
    /// - Returns: `true` once when the accumulated time first reaches `requiredDuration`.
    mutating func tick(isConditionMet: Bool, deltaTime: TimeInterval) -> Bool {
        if isConditionMet {
            if !isFired {
                accumulated += deltaTime
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