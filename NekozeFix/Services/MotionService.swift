import CoreMotion
import Foundation

/// サービス層: 重力の取得・無効保持を所有する。
///
/// design.md "MotionService（新設）" 参照。
/// Requirements 4.1（天方向基準・代替鎖への nil 合図）、
/// 7.1（向き追従）、9.1（電池・1/30間隔＋起停限定）。
/// motion-frequency（ADR-0023）: 重力取得頻度の設定・二段比較・区間計測を所有する。
/// 保持・変換・代替鎖・起停の既存契約は不変。
///
/// 方向の扱い（14.2 実機検収の知見＋landscape修正）:
/// キャプチャ接続の videoRotationAngle により、Vision に渡るバッファは常に向き補正済み
/// （デバイス上端＝バッファ上端）で渡る。重力のデバイス座標 (gx, gy) から求まる天方向 K は
/// センサ固定のため、バッファ座標系で表すには直近capture角θの(θ−90°)回転が必要であり、
/// Session受渡し時（analyze）に適用する（未確定時は無回転）。取得式自体は向き非依存のまま。
/// 旧来の向き別変換表はセンサ固定フレームの誤った想定＋前面鏡の二重適用であり、14.2 で
/// 右傾き時の鏡像反転として発覚したため撤去した。Session 側の向き購読（自動再校正・
/// プレビュー/出力接続の向き同期）は別系統であり、本サービスは向きを持たない。
@MainActor
final class MotionService {
    /// 無効時の直前有効値ホールド秒数（単一タイマ、設計値・実装内に閉じる）。
    static let holdDuration = 0.5
    /// 実質同一判定の許容差（単位ベクトルのユークリッド距離）。
    /// 暫定値。事前分布計測 `00-gravity-noise`（ノイズp99 < ε < 動作p5）で確定する（ADR-0023）。
    static let equalityTolerance = 1e-4

    /// キーポイント空間に変換済みの最新重力（単位化済み）または nil。
    /// 公開値（受動公開・pull）。nil は代替解決への合図。テストは @testable で直接代入する。
    var latestGravityInKeypointSpace: SIMD2<Double>?

    /// 重力取得頻度の設定（内部保持、既定は毎秒15回）。許可値は3値enumに閉じる。
    private(set) var updateFrequency: MotionUpdateFrequency = .fifteenHz

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

    /// background（motionQueue直列）とMainで共有する状態。
    /// `lastSent`（最終hop済み値）は送信成否のみに使い、保持・ホールド則の状態ではない。
    /// 計測カウンタはここに集約し、取得・判定の動作には影響させない。
    private final class SharedState: @unchecked Sendable {
        let lock = NSLock()
        var lastSent: SIMD2<Double>?
        var measuring = false
        var measureFrequency: MotionUpdateFrequency = .fifteenHz
        var measureStart: Date?
        var measureNote = ""
        var sampleCount = 0
        var dispatchCount = 0
        var consumptionCount = 0
        var invalidCount = 0

        /// 計測中の公開値書換えを数える（ingest内3箇所の重複形の集約）。
        /// 錠の取得まで含むため、呼出し側でlockを取ってはならない。
        func bumpDispatchIfMeasuring() {
            lock.withLock {
                if measuring {
                    dispatchCount += 1
                }
            }
        }
    }

    private let shared = SharedState()

    init() {}

    /// 監視・校正開始時に呼ぶ。停止・背景移行時は stop で止める（暗転中は継続）。
    func start() {
        guard !isRunning else { return }
        isRunning = true
        beginMotionUpdates()
    }

    /// 監視停止・背景移行時に呼ぶ。保持値を破棄し nil に戻す（停止中は nil 扱い）。
    /// background の最終hop済み値も破棄し、次回初回は無条件hopとする（Q15）。
    func stop() {
        isRunning = false
        motionManager.stopDeviceMotionUpdates()
        lastValidVector = nil
        lastValidTime = nil
        latestGravityInKeypointSpace = nil
        shared.lock.withLock {
            shared.lastSent = nil
        }
    }

    /// 重力取得頻度の設定（motion-frequency Task 2.1・ADR-0023）。
    /// 許可値は3値enumに閉じるため許可外値は型で排除される。
    /// 動作中は即時再開（stop→新間隔→startを原子的に行う）、停止中は次回開始時から反映する（Q11）。
    /// 保持・変換・起停の既存則は変えない。
    func setUpdateFrequency(_ frequency: MotionUpdateFrequency) {
        updateFrequency = frequency
        guard isRunning else { return }
        motionManager.stopDeviceMotionUpdates()
        beginMotionUpdates()
    }

    /// 取得開始の実体。`isRunning==true` の前提で新間隔を反映して開始する。
    /// シミュレータ・未対応端末・権限拒否では持続的に nil を返す。
    private func beginMotionUpdates() {
        guard motionManager.isDeviceMotionAvailable else { return }
        motionManager.deviceMotionUpdateInterval = updateFrequency.interval
        let box = shared
        motionManager.startDeviceMotionUpdates(to: motionQueue) { motion, _ in
            // background（直列）一段目：変換＋比較し、実質同一の有効値はhop自体を起こさない。
            // 無効（nil・平置き）は全てhopする（Q14）。初回・破棄後は無条件hopする（Q15）。
            box.lock.withLock {
                if box.measuring {
                    box.sampleCount += 1
                }
            }
            let converted: SIMD2<Double>?
            if let gravity = motion?.gravity {
                converted = Self.convert(gravity: gravity)
            } else {
                converted = nil
            }
            let shouldHop: Bool = box.lock.withLock {
                let decision = Self.hopDecision(converted: converted, lastSent: box.lastSent)
                box.lastSent = decision.newLastSent
                return decision.shouldHop
            }
            guard shouldHop else { return }
            Task { @MainActor [weak self] in
                self?.ingest(converted: converted, now: Date())
            }
        }
    }

    // MARK: - 区間計測（メモリ内のみ、永続化なし）

    /// 計測区間を開始する。カウンタを初期化し、条件注記を付す。
    /// 二重開始は区間を再開始する（計測のみに影響し取得・判定には影響しない）。
    func startMeasuring(note: String) {
        shared.lock.withLock {
            shared.measuring = true
            shared.measureFrequency = updateFrequency
            shared.measureStart = Date()
            shared.measureNote = note
            shared.sampleCount = 0
            shared.dispatchCount = 0
            shared.consumptionCount = 0
            shared.invalidCount = 0
        }
    }

    /// 計測区間を終了し結果を取出す。未開始の終了は空計測を返し取得・判定には影響しない。
    func stopMeasuring() -> MotionFrequencyMeasurement {
        shared.lock.withLock {
            let end = Date()
            let duration: TimeInterval
            if let start = shared.measureStart, shared.measuring {
                duration = end.timeIntervalSince(start)
            } else {
                duration = 0
            }
            let measurement = MotionFrequencyMeasurement(
                frequency: shared.measureFrequency,
                duration: duration,
                sampleCount: shared.sampleCount,
                dispatchCount: shared.dispatchCount,
                consumptionCount: shared.consumptionCount,
                invalidCount: shared.invalidCount,
                conditionNote: shared.measureNote
            )
            shared.measuring = false
            shared.measureStart = nil
            return measurement
        }
    }

    /// Session の判定読取りに付随する参照記録。読取り則自体は変えない。
    /// 通知漏れがあっても判定結果には影響しない。
    func noteConsumption(hasValue: Bool) {
        shared.lock.withLock {
            guard shared.measuring else { return }
            shared.consumptionCount += 1
            if !hasValue {
                shared.invalidCount += 1
            }
        }
    }

    // MARK: - 変換（向き非依存、14.2 実機知見）

    /// 重力→天方向の純粋変換。平置き・正規化不能は nil。
    ///
    /// 天方向 `u = (−gx, −gy)` を単位化して返す（デバイス座標系。向き非依存）。
    /// バッファ座標系への(θ−90°)回転は Session受渡し時（analyze の captureAngleDegrees）に適用する。
    /// したがって向き別の回転表・鏡像は不要であり、向き引数は持たない。
    /// 平置き（z支配）は無効として代替鎖へ退行させる。
    nonisolated static func convert(gravity: CMAcceleration) -> SIMD2<Double>? {
        guard abs(gravity.z) <= abs(gravity.x) || abs(gravity.z) <= abs(gravity.y) else {
            return nil
        }
        let u = SIMD2<Double>(-gravity.x, -gravity.y)
        let length = (u.x * u.x + u.y * u.y).squareRoot()
        guard length.isFinite && length > 1e-9 else { return nil }
        return u / length
    }

    /// 実質同一判定（単位ベクトルのユークリッド距離が許容差未満）。
    /// background一段目とMain二段目で同一則を用いる（Q9一本化）。
    nonisolated static func isEffectivelySame(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Bool {
        let dx = a.x - b.x
        let dy = a.y - b.y
        let distance = (dx * dx + dy * dy).squareRoot()
        return distance < Self.equalityTolerance
    }

    /// background一段目のhop要否判定（純関数・現行則の抽出）。
    /// 無効は全てhopし、比較基準（最終hop済み値）を破棄する。無効区間後の初回有効値を
    /// 無条件hopさせるためであり、Q15破棄則の無効hopへの拡張（PR #25 指摘2対応）。
    /// 実質同一の有効値はhopせず基準を維持する。初回・基準なしは無条件hopする。
    nonisolated static func hopDecision(converted: SIMD2<Double>?, lastSent: SIMD2<Double>?) -> (shouldHop: Bool, newLastSent: SIMD2<Double>?) {
        guard let value = converted else {
            return (true, nil)
        }
        if let last = lastSent, isEffectivelySame(value, last) {
            return (false, last)
        }
        return (true, value)
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
    /// 実質同一の有効値は公開値の更新を抑制する（判定結果は不変）。変化時と状態変化時は必ず更新する。
    func ingest(converted: SIMD2<Double>?, now: Date) {
        if let converted {
            lastValidVector = converted
            lastValidTime = now
            if let current = latestGravityInKeypointSpace,
               Self.isEffectivelySame(converted, current) {
                return
            }
            latestGravityInKeypointSpace = converted
            shared.bumpDispatchIfMeasuring()
            return
        }
        guard let last = lastValidVector,
              let lastTime = lastValidTime,
              now.timeIntervalSince(lastTime) <= Self.holdDuration else {
            let hadValue = latestGravityInKeypointSpace != nil
            latestGravityInKeypointSpace = nil
            if hadValue {
                shared.bumpDispatchIfMeasuring()
            }
            return
        }
        if let current = latestGravityInKeypointSpace,
           Self.isEffectivelySame(last, current) {
            latestGravityInKeypointSpace = last
            return
        }
        latestGravityInKeypointSpace = last
        shared.bumpDispatchIfMeasuring()
    }
}
