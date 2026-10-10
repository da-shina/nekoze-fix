import Foundation

/// 時刻間隔によるVision推論の間引き判定器。
///
/// 前回推論時刻との間隔が上限間隔以上の場合のみ推論対象とする。
/// 無効時刻（NaN・負・無限大）のフレームは推論対象として扱い、検出機会を保つ。
/// 判定経路は検出キュー直列実行のため錠不要。プロセス内メモリのみ。
/// 上限切替え（`setLimit`）はタスク1.3の範囲であり、本型は含まない。
/// 計数（入力到達数・推論実行数など）はタスク1.2の範囲であり、本型は含まない。
///
/// 設計参照: `.kiro/specs/vision-fps-throttle/design.md`「Session / FrameThrottle 間引き判定器」。
/// 既定の上限は暫定値であり、最終選定はタスク3.3の実測比較（現状・15・10FPS）に委ねる。
struct FrameThrottle {
    /// 暫定の既定上限FPS。最終選定はタスク3.3の実測比較で行う。
    static let defaultMaxFPS: Double = 15.0

    /// 推論FPSの上限。注入時に定まる。
    private(set) var maxFPS: Double
    /// 上限間隔（秒）。`1.0 / maxFPS` から導出される。
    var minInterval: TimeInterval { 1.0 / maxFPS }

    /// 前回推論対象としたフレームの提示時刻。未推論・初期化直後は nil。
    private var lastInferenceTime: TimeInterval?

    /// - Parameter maxFPS: 推論FPSの上限（正の有限値）。不正値は既定値に倒す。
    init(maxFPS: Double = FrameThrottle.defaultMaxFPS) {
        if maxFPS.isFinite, maxFPS > 0 {
            self.maxFPS = maxFPS
        } else {
            self.maxFPS = FrameThrottle.defaultMaxFPS
        }
    }

    /// 提示時刻が推論対象かを判定する。呼出ごとに1回のみ判定する。
    /// - Parameter timestamp: フレームの提示時刻（秒単位）。
    /// - Returns: 推論対象なら true。対象時は前回推論時刻を更新し、
    ///   対象外時と無効時刻時は状態を変えない。
    mutating func shouldInfer(at timestamp: TimeInterval) -> Bool {
        guard timestamp.isFinite, timestamp >= 0 else {
            return true
        }
        guard let last = lastInferenceTime else {
            lastInferenceTime = timestamp
            return true
        }
        if timestamp - last >= minInterval - 1e-9 {
            lastInferenceTime = timestamp
            return true
        }
        return false
    }

    /// 判定状態を初期化する（前回推論時刻をクリア）。
    mutating func reset() {
        lastInferenceTime = nil
    }
}
