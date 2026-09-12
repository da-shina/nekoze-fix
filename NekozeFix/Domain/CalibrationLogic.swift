import Foundation

/// キャリブレーションロジックを扱うドメイン構造体。
/// 安定した姿勢角度の蓄積と基準値の管理を行う。
struct CalibrationLogic {
    // MARK: - 状態

    private var accumulatedAngles: [Double] = []
    private var accumulatedPoints: [[CGPoint]] = []
    private var isAccumulating = false
    private var personPresent = false
    private var lastAngle: Double = 0.0
    private var lastTime: TimeInterval = 0
    private var accumulationStartTime: TimeInterval = 0

    // MARK: - 公開API

    /// 新しいキャリブレーションセッションを開始する。
    /// 以前の基準値は上書きされる。
    mutating func start() {
        accumulatedAngles = []
        accumulatedPoints = []
        isAccumulating = false
        personPresent = false
        lastAngle = 0.0
        lastTime = 0
        accumulationStartTime = 0
    }

    /// 姿勢サンプルと人物検出状態を処理する。
    /// - Parameters:
    ///   - sample: PostureAnalyzer からの角度サンプル（有効な角度がない場合は nil）
    ///   - presence: 人物検出状態
    ///   - now: 現在の時刻間隔
    ///   - points: 可視化ポイント（6点: 0左肩 1右肩 2左耳 3右耳 4近傍耳 5近傍肩）
    /// - Returns: キャリブレーション進捗状態
    mutating func ingest(sample: AngleSample?, presence: DetectionPresence, now: TimeInterval, points: [CGPoint] = []) -> CalibrationProgress {
        // 人物が見つからない場合 - 即座にリセット
        if presence == .personMissing {
            accumulatedAngles = []
            accumulatedPoints = []
            isAccumulating = false
            return .waitingForPerson
        }

        // 人物検出状態を更新
        self.personPresent = presence == .personDetected

        // 人物が検出されなければ待機
        if !personPresent {
            return .waitingForPerson
        }

        // サンプルの有無を処理
        if let sample = sample {
            // 有効な角度サンプルがあり、まだ蓄積中でなければ蓄積を開始
            if !isAccumulating {
                // 最初の有効サンプルで蓄積を開始
                accumulatedAngles = [sample.nearAngleDegrees]
                accumulatedPoints = [points]
                isAccumulating = true
                lastAngle = sample.nearAngleDegrees
                lastTime = now
                accumulationStartTime = now
                return .accumulating(elapsed: 0)
            }

            // lastAngle 更新前に姿勢の不安定さをチェック（角度変化 > 5度）
            let angleDelta = abs(sample.nearAngleDegrees - lastAngle)

            lastAngle = sample.nearAngleDegrees
            lastTime = now
            if angleDelta > 5.0 {
                // 不安定な場合は蓄積をリセット
                accumulatedAngles = [sample.nearAngleDegrees]
                accumulatedPoints = [points]
                lastAngle = sample.nearAngleDegrees
                lastTime = now
                accumulationStartTime = now
                return .accumulating(elapsed: 0)
            }

            // 新しい角度を蓄積に追加
            accumulatedAngles.append(sample.nearAngleDegrees)
            if !points.isEmpty {
                accumulatedPoints.append(points)
            }
        }

        // 蓄積が完了に十分かチェック（3秒間の安定した姿勢）
        // ~60fps では、3秒の安定検出に約180フレームが必要
        if isAccumulating && accumulatedAngles.count >= 180 { // 3 seconds * 60 fps
            // 蓄積された角度の平均を計算
            let average = accumulatedAngles.reduce(0.0, +) / Double(accumulatedAngles.count)
            let finalPoints = accumulatedPoints.last ?? []
            let completedProgress = CalibrationProgress.completed(referenceNearAngleDegrees: average, referencePoints: finalPoints)

            // 完了後に状態をリセット
            accumulatedAngles = []
            accumulatedPoints = []
            isAccumulating = false

            return completedProgress
        }

        // 蓄積中だがまだ完了していない場合
        if isAccumulating {
            let elapsed = now - accumulationStartTime
            return CalibrationProgress.accumulating(elapsed: max(elapsed, 0))
        }

        // デフォルト状態
        return .waitingForPerson
    }
}