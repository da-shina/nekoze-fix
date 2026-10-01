import CoreMotion
import Foundation

/// サービス層: 重力の取得・無効保持を所有する。
///
/// design.md "MotionService（新設）" 参照。
/// Requirements 4.1（天方向基準・代替鎖への nil 合図）、
/// 7.1（向き追従）、9.1（電池・1/30間隔＋起停限定）。
///
/// 方向の扱い（14.2 実機検収の知見）:
/// キャプチャ接続の videoRotationAngle により、Vision に渡るバッファは常に向き補正済み
/// （デバイス上端＝バッファ上端）で渡る。このため重力のデバイス座標 (gx, gy) は
/// バッファ座標と軸一致し、向き別の回転表は不要である。天方向 K は常に
/// `normalize(−gx, −gy)` で求まる（向き非依存）。旧来の向き別変換表は
/// センサ固定フレームの誤った想定＋前面鏡の二重適用であり、14.2 で右傾き時の
/// 鏡像反転として発覚したため撤去した。Session 側の向き購読（自動再校正・
/// プレビュー/出力接続の向き同期）は別系統であり、本サービスは向きを持たない。
final class MotionService {
    /// モーション取得間隔（1/30秒）。電池制約 9.1 のため最小限の頻度に抑制。
    static let updateInterval = 1.0 / 30.0
    /// 無効時の直前有効値ホールド秒数（単一タイマ、設計値・実装内に閉じる）。
    static let holdDuration = 0.5

    /// キーポイント空間に変換済みの最新重力（単位化済み）または nil。
    /// nil は代替解決への合図。テストは @testable で直接代入する。
    var latestGravityInKeypointSpace: SIMD2<Double>?

    private let motionManager = CMMotionManager()
    private let motionQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.nekozefix.motion"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private var lastValidVector: SIMD2<Double>?
    private var lastValidTime: Date?
    /// Session 駆動のライフサイクル状態（start 済み・未 stop）。テストは @testable で読む。
    /// シミュレータ等の取得不可環境でも start/stop の対応は保持する（値は持続 nil）。
    private(set) var isRunning = false

    init() {}

    /// 監視・校正開始時に呼ぶ。停止・背景移行時は stop で止める（暗転中は継続）。
    func start() {
        guard !isRunning else { return }
        isRunning = true
        // シミュレータ・未対応端末・権限拒否では持続的に nil を返す。
        guard motionManager.isDeviceMotionAvailable else { return }
        motionManager.deviceMotionUpdateInterval = Self.updateInterval
        motionManager.startDeviceMotionUpdates(to: motionQueue) { [weak self] motion, _ in
            self?.ingest(gravity: motion?.gravity, now: Date())
        }
    }

    /// 監視停止・背景移行時に呼ぶ。保持値を破棄し nil に戻す（停止中は nil 扱い）。
    func stop() {
        isRunning = false
        motionManager.stopDeviceMotionUpdates()
        lastValidVector = nil
        lastValidTime = nil
        latestGravityInKeypointSpace = nil
    }

    // MARK: - 変換（向き非依存、14.2 実機知見）

    /// 重力→天方向の純粋変換。平置き・正規化不能は nil。
    ///
    /// 天方向 `u = (−gx, −gy)` を単位化して返す。キャプチャ接続が出力向きに応じて
    /// バッファを物理回転させるため、デバイス座標はバッファ座標と軸一致する。
    /// したがって向き別の回転・鏡像は不要であり、向き引数は持たない。
    /// 平置き（z支配）は無効として代替鎖へ退行させる。
    static func convert(gravity: CMAcceleration) -> SIMD2<Double>? {
        guard abs(gravity.z) <= abs(gravity.x) || abs(gravity.z) <= abs(gravity.y) else {
            return nil
        }
        let u = SIMD2<Double>(-gravity.x, -gravity.y)
        let length = (u.x * u.x + u.y * u.y).squareRoot()
        guard length.isFinite && length > 1e-9 else { return nil }
        return u / length
    }

    // MARK: - 取得と単一ホールド

    /// 生サンプルをホールド則で解決する単一入口。nil は未取得を表す。
    func ingest(gravity: CMAcceleration?, now: Date) {
        guard let gravity else {
            ingest(converted: nil, now: now)
            return
        }
        ingest(converted: Self.convert(gravity: gravity), now: now)
    }

    /// 変換済みサンプル（nil＝無効）をホールド則で解決する。回復時は即時復帰、通知なし。
    func ingest(converted: SIMD2<Double>?, now: Date) {
        if let converted {
            lastValidVector = converted
            lastValidTime = now
            latestGravityInKeypointSpace = converted
            return
        }
        guard let last = lastValidVector,
              let lastTime = lastValidTime,
              now.timeIntervalSince(lastTime) <= Self.holdDuration else {
            latestGravityInKeypointSpace = nil
            return
        }
        latestGravityInKeypointSpace = last
    }
}
