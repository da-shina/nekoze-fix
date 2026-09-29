import AVFoundation
import CoreMotion
import Foundation

/// サービス層: 重力の取得・画像座標変換・無効保持を所有する。
///
/// design.md "MotionService（新設）" 参照。
/// Requirements 4.1（天方向基準・代替鎖への nil 合図）、
/// 7.1（向き追従・取得時点の向きと同時変換）、9.1（電池・1/30間隔＋起停限定）。
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
    /// 向きの参照元。Session からの provider 配線なしで直接所有する。
    private lazy var orientationMonitor = DeviceOrientationMonitor()
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
        let monitor = orientationMonitor
        motionManager.startDeviceMotionUpdates(to: motionQueue) { [weak self] motion, _ in
            guard let self, let motion else {
                self?.ingest(converted: nil, now: Date())
                return
            }
            // 重力サンプル取得時点の向きと同時に変換する（別タイミングの向きと組合わせない）。
            self.ingest(
                gravity: motion.gravity,
                videoOrientation: monitor.currentVideoOrientation,
                now: Date()
            )
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

    // MARK: - 変換（全組み合わせ固定、grill Q2決定）

    /// 重力＋向き→キーポイント空間の純粋変換。無効（平置き・正規化不能・未知）は nil。
    ///
    /// 合成規則: 天方向 `u = (−gx, −gy)` に対し `K = mirror(R(V) · u)`。
    /// 前面固定のため鏡は定数（x反転。CameraSessionManager の前面 mirrored 則に準拠）。
    /// 下表の変換式は鏡込みの最終形である。
    static func convert(
        gravity: CMAcceleration,
        videoOrientation: AVCaptureVideoOrientation
    ) -> SIMD2<Double>? {
        // 平置き（z支配）は無効として代替鎖へ退行させる。
        guard abs(gravity.z) <= abs(gravity.x) || abs(gravity.z) <= abs(gravity.y) else {
            return nil
        }
        let u = SIMD2<Double>(-gravity.x, -gravity.y)
        let converted: SIMD2<Double>
        switch videoOrientation {
        case .portrait:
            converted = SIMD2<Double>(-u.x, u.y)
        case .portraitUpsideDown:
            converted = SIMD2<Double>(u.x, -u.y)
        case .landscapeRight:
            converted = SIMD2<Double>(u.y, u.x)
        case .landscapeLeft:
            converted = SIMD2<Double>(-u.y, -u.x)
        @unknown default:
            return nil
        }
        let length = (converted.x * converted.x + converted.y * converted.y).squareRoot()
        guard length > 1e-9 else { return nil }
        return converted / length
    }

    // MARK: - 取得と単一ホールド

    /// 生サンプルを取得時点の向きと同時変換する単一入口。nil は未取得・向き不明を表す。
    func ingest(
        gravity: CMAcceleration?,
        videoOrientation: AVCaptureVideoOrientation?,
        now: Date
    ) {
        guard let gravity, let videoOrientation else {
            ingest(converted: nil, now: now)
            return
        }
        ingest(converted: Self.convert(gravity: gravity, videoOrientation: videoOrientation), now: now)
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
