import Foundation
import QuartzCore

/// スレッドセーフな長時間不在トラッカー（Session層・`@unchecked Sendable` クラス）。
///
/// `MotionService.SharedState` と同パターンで NSLock による内部同期を行う。
/// 人物不在継続時間を単調時計（`CACurrentMediaTime` 系）で計測し、
/// 不在しきい値（既定 60 秒、`DimPowerPolicy.defaultAbsentThreshold` 共用）超過で長時間不在状態へ遷移する。
/// 顔フォールバック間引き間隔（既定 5 秒）を内部に保持し、スレッドセーフに実行可否を判定・記録する。
/// 暗転段階遷移（`DimPowerPolicy`）とは独立に動作する。
final class ProlongedAbsenceTracker: FaceFallbackGating, @unchecked Sendable {
    /// 不在しきい値（秒）。既定は DimPowerPolicy.defaultAbsentThreshold (60s)。
    let absentThreshold: TimeInterval
    /// 顔フォールバック間引き間隔（秒）。既定 5 秒。
    let faceFallbackThrottleInterval: TimeInterval

    private let lock = NSLock()

    /// 現在長時間不在中か
    private var _isProlongedAbsence: Bool = false
    /// 不在計測開始時刻（単調時計）。人物検出中・非長時間不在時は nil。
    private var absenceStart: TimeInterval?
    /// 最後に顔フォールバックを実行した時刻（単調時計）。初期値は遠過去相当。
    private var lastFaceExecutionTime: TimeInterval = -.infinity
    /// 最後に顔検出（.personOnly または .pose）した時刻。顔実行ホールド用。
    private var lastFaceDetectedTime: TimeInterval?

    /// - Parameters:
    ///   - absentThreshold: 人物なし継続秒数（正の有限値）。不正値は既定値に倒す。
    ///   - faceFallbackThrottleInterval: 顔フォールバック最小実行間隔（正の有限値）。不正値は既定値に倒す。
    init(
        absentThreshold: TimeInterval = DimPowerPolicy.defaultAbsentThreshold,
        faceFallbackThrottleInterval: TimeInterval = 5.0
    ) {
        self.absentThreshold = (absentThreshold.isFinite && absentThreshold > 0) ? absentThreshold : DimPowerPolicy.defaultAbsentThreshold
        self.faceFallbackThrottleInterval = (faceFallbackThrottleInterval.isFinite && faceFallbackThrottleInterval > 0) ? faceFallbackThrottleInterval : 5.0
    }

    /// 現在長時間不在中か（ロック保護付き読み取り）。
    var isProlongedAbsence: Bool {
        lock.withLock { _isProlongedAbsence }
    }

    /// 検出結果による長時間不在判定・遷移。
    /// 顔検出ホールドの時刻更新は行わない(`recordFaceDetected(now:)` が更新する)。
    /// - Parameters:
    ///   - isPersonDetected: デバウンス済み人物検出状態（`updateState` 確定後の値）
    ///   - now: 単調時刻系（`CACurrentMediaTime` 系）。無効時刻は遷移を見送る。
    /// - Returns: 更新後の `isProlongedAbsence`
    func tick(isPersonDetected: Bool, now: TimeInterval) -> Bool {
        return lock.withLock {
            guard now.isFinite, now >= 0 else { return _isProlongedAbsence }
            if isPersonDetected {
                absenceStart = nil
                if _isProlongedAbsence {
                    _isProlongedAbsence = false
                }
                return _isProlongedAbsence
            }
            guard _isProlongedAbsence == false else { return true } // 既に長時間不在なら継続
            guard let start = absenceStart else {
                absenceStart = now
                return false
            }
            guard now >= start else {
                absenceStart = now
                return false
            }
            if now - start > absentThreshold {
                _isProlongedAbsence = true
            }
            return _isProlongedAbsence
        }
    }

    /// 顔フォールバックをこの推論で実行すべきか判定し、実行可なら時刻を記録する。
    /// 長時間不在中かつ前回実行から間引き間隔以上経過なら true を返し、内部で実行時刻を更新する。
    /// ここでは顔検出結果を得る前のため `lastFaceDetectedTime` は更新しない。
    /// - Parameter now: 単調時刻系（`CACurrentMediaTime` 系）。
    /// - Returns: 実行すべきなら true。呼び出し側は true 時にのみ顔検出を実行する。
    func shouldExecuteAndRecordFaceFallback(now: TimeInterval) -> Bool {
        return lock.withLock {
            // 長時間不在でなければ毎回実行する。ここでは実行時刻を記録しない:
            // 記録すると長時間不在へ移行した直後の初回実行が間引き間隔ぶん待たされ、
            // 復帰検出(要件 3.2)を遅らせる。間引き判定は長時間不在中のみ意味を持つ。
            guard _isProlongedAbsence else { return true }
            guard now.isFinite, now >= 0 else { return true }
            if now - lastFaceExecutionTime < faceFallbackThrottleInterval {
                return false
            }
            lastFaceExecutionTime = now
            return true
        }
    }

    /// 顔検出が実行された（`.personOnly` を返した）ことを通知し、ホールド時刻を更新する。
    /// 顔フォールバック経路は `synthesize(pose: nil, faceBounds:)` のため `.pose` は返らない。
    /// `shouldExecuteAndRecordFaceFallback` が true を返した後、実際に顔リクエストを発行して結果を得た場合に呼ぶ。
    func recordFaceDetected(now: TimeInterval) {
        lock.withLock {
            guard now.isFinite, now >= 0 else { return }
            lastFaceDetectedTime = now
        }
    }

    /// 顔検出ホールドが有効か（最後に顔検出してから間引き間隔未満か）。
    /// `updateState` で表示用の `isPersonDetected` を `true` に維持するか判定するために使用。
    /// 実検出状態とは分離し、表示ちらつき抑制のみに用いる。
    /// - Parameter now: 単調時刻系（`CACurrentMediaTime` 系）。
    /// - Returns: 長時間不在中かつホールド期間内なら true。
    func faceDetectedHoldActive(now: TimeInterval) -> Bool {
        lock.withLock {
            // 注意: ここではロック保持中のため、ロックを再取得する計算プロパティ
            // `isProlongedAbsence` を参照しない（NSLock 非再入のため再入するとデッドロックする）。
            // 格納プロパティ `_isProlongedAbsence` を直接読む。
            guard _isProlongedAbsence else { return false }
            guard let last = lastFaceDetectedTime else { return false }
            return now - last < faceFallbackThrottleInterval
        }
    }

    /// 長時間不在解除・監視開始・復帰時に状態をリセットする。
    func reset() {
        lock.withLock {
            _isProlongedAbsence = false
            absenceStart = nil
            lastFaceExecutionTime = -.infinity
            lastFaceDetectedTime = nil
        }
    }

    /// 現在の状態をスナップショットとして取得（テスト・ログ用）。
    struct Snapshot: Equatable {
        let isProlongedAbsence: Bool
        let absenceStart: TimeInterval?
        let lastFaceExecutionTime: TimeInterval
        let lastFaceDetectedTime: TimeInterval?
    }
    func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(
                isProlongedAbsence: _isProlongedAbsence,
                absenceStart: absenceStart,
                lastFaceExecutionTime: lastFaceExecutionTime,
                lastFaceDetectedTime: lastFaceDetectedTime
            )
        }
    }
}