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
    private var lastTickTime: TimeInterval? = nil

    init(requiredDuration: TimeInterval) {
        self.requiredDuration = requiredDuration
    }

    /// Call each frame with the current condition state and timestamp.
    /// - Returns: `true` once when the accumulated time first reaches `requiredDuration`.
    mutating func tick(isConditionMet: Bool, now: TimeInterval) -> Bool {
        if isConditionMet {
            if let last = lastTickTime {
                accumulated += now - last
            }
            lastTickTime = now

            if !isFired && accumulated >= requiredDuration {
                isFired = true
                return true
            }
        } else {
            accumulated = 0
            isFired = false
            lastTickTime = nil
        }
        return false
    }

    mutating func reset() {
        accumulated = 0
        isFired = false
        lastTickTime = nil
    }
}