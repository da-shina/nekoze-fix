import Foundation

/// キャリブレーションロジックを扱うドメイン構造体。
/// 安定した姿勢角度の蓄積と基準値の管理を行う。
struct CalibrationLogic {
    // MARK: - 定数

    /// 完了に必要な連続安定時間（秒）。サンプル数ではなく実時間で判定するため、
    /// デバイス性能による実効 fps 差の影響を受けない。
    static let requiredStableDuration: TimeInterval = 3.0
    /// 安定性判定に用いる直近サンプル数（中央値ベース）
    private static let stabilityWindowSize = 7
    /// 中央値からの角度変化がこの度数を超えたら姿勢崩れとみなす
    private static let angleResetThresholdDegrees: Double = 5.0

    // MARK: - 状態

    private var accumulatedAngles: [Double] = []
    private var accumulatedPoints: [[CGPoint]] = []
    private var isAccumulating = false
    private var lastTime: TimeInterval = 0
    private var accumulationStartTime: TimeInterval = 0

    // MARK: - 公開API

    /// 新しいキャリブレーションセッションを開始する。
    /// 以前の基準値は上書きされる。
    mutating func start() {
        accumulatedAngles = []
        accumulatedPoints = []
        isAccumulating = false
        lastTime = 0
        accumulationStartTime = 0
    }

    /// 姿勢サンプルと人物検出状態を処理する。
    /// - Parameters:
    ///   - sample: PostureAnalyzer からの角度サンプル（有効な角度がない場合は nil）
    ///   - presence: 人物検出状態（デバウンス確定済みの値を渡す。猶予期間中は .personDetected）
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

        lastTime = now

        // サンプルの有無を処理
        if let sample = sample {
            if !isAccumulating {
                // 最初の有効サンプルで蓄積を開始
                accumulatedAngles = [sample.nearAngleDegrees]
                accumulatedPoints = [points]
                isAccumulating = true
                accumulationStartTime = now
                return .accumulating(elapsed: 0)
            }

            // 安定性チェック: 直近 windowSize サンプルの中央値比。
            // フレーム単位の Vision ジッタは吸収し、実際の姿勢移動のみ検出する。
            let window = Array(accumulatedAngles.suffix(Self.stabilityWindowSize))
            let median = Self.median(of: window)
            if abs(sample.nearAngleDegrees - median) > Self.angleResetThresholdDegrees {
                // 不安定な場合は蓄積をリセット
                accumulatedAngles = [sample.nearAngleDegrees]
                accumulatedPoints = [points]
                accumulationStartTime = now
                return .accumulating(elapsed: 0)
            }

            // 新しい角度を蓄積に追加
            accumulatedAngles.append(sample.nearAngleDegrees)
            if !points.isEmpty {
                accumulatedPoints.append(points)
            }
        }

        // 蓄積が完了に十分かチェック（requiredStableDuration 間の安定した姿勢）
        if isAccumulating && now - accumulationStartTime >= Self.requiredStableDuration {
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

    // MARK: - プライベートメソッド

    private static func median(of values: [Double]) -> Double {
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 1 {
            return sorted[mid]
        }
        return (sorted[mid - 1] + sorted[mid]) / 2.0
    }
}
