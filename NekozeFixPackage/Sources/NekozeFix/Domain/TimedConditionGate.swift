import Foundation

/// N秒間の継続的条件ゲート。
///
/// `isConditionMet == true` の間のみ時間を蓄積する。
/// 条件がfalseになると、アキュムレータは即座にリセットされる。
/// 蓄積時間が `requiredDuration` に達すると、`tick` は1回だけ `true` を返す。
///
/// 設計参照: design.md "TimedConditionGate" セクション。
struct TimedConditionGate {
    var requiredDuration: TimeInterval
    private var accumulated: TimeInterval = 0
    private var isFired: Bool = false
    private var lastTickTime: TimeInterval? = nil

    init(requiredDuration: TimeInterval) {
        self.requiredDuration = requiredDuration
    }

    /// 各フレームで現在の条件状態とタイムスタンプと共に呼び出す。
    /// - 戻り値: 蓄積時間が初めて `requiredDuration` に達したときに1回だけ `true` を返す。
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