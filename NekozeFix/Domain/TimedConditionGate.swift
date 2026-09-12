import Foundation

/// N秒間の連続条件ゲート。
///
/// `isConditionMet == true` の間のみ時間を蓄積する。
/// 条件が false になると蓄積は即座にリセットされる。
/// 蓄積時間が `requiredDuration` に達すると、`tick` は一度だけ `true` を返す。
///
/// 設計参照: design.md "TimedConditionGate" セクション。
struct TimedConditionGate: Equatable {
    var requiredDuration: TimeInterval
    var accumulated: TimeInterval = 0
    var isFired: Bool = false

    init(requiredDuration: TimeInterval) {
        self.requiredDuration = requiredDuration
    }

    /// フレームごとに現在の条件状態と経過時間 delta で呼び出す。
    /// - Parameters:
    ///   - isConditionMet: ゲート条件が現在満たされているか
    ///   - deltaTime: 前回の tick からの経過時間
    /// - Returns: 蓄積時間が初めて `requiredDuration` に達した時に一度だけ `true`。
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