import Foundation

/// キャリブレーションロジックを扱うドメイン構造体。
/// 安定した姿勢角度の蓄積と基準値の管理を行う。
struct CalibrationLogic {
    // MARK: - 定数

    /// 完了に必要な連続安定時間（秒）。サンプル数ではなく実時間で判定するため、
    /// デバイス性能による実効 fps 差の影響を受けない。
    static let requiredStableDuration: TimeInterval = 5.0
    /// 安定性判定に用いる直近サンプル数（中央値ベース）
    private static let stabilityWindowSize = 7
    /// 中央値からの角度変化がこの度数を超えたら姿勢崩れとみなす
    private static let angleResetThresholdDegrees: Double = 5.0
    /// キーポイント脱落（sample nil）および personMissing の許容時間（秒）。
    /// Vision 観測のチラつき・一時的な人物消失は、この間だけ経過時間の加算を凍結し、
    /// 蓄積は保持する。超えたら姿勢崩れ扱いでリセット。
    static let dropoutTolerance: TimeInterval = 1.0

    // MARK: - 状態

    private var accumulatedAngles: [Double] = []
    private var accumulatedDistances: [Double] = []
    private var accumulatedPoints: [[CGPoint]] = []
    private var isAccumulating = false
    /// 有効サンプルが蓄積された時間の合計（秒）。脱落中は加算されない。
    private var accumulatedDuration: TimeInterval = 0
    /// 直近の有効サンプル時刻（次回有効サンプルとの差分を accumulatedDuration に加算する基準）
    private var lastSampleTime: TimeInterval = 0
    /// 許容時間内の脱落中か。true の間は有効サンプルが復帰しても脱落区間の時間を計上しない
    private var dropoutActive = false
    /// 現在の蓄積窓を開始した近側（FQ1・validate-design Issue 1）。
    /// 左右の耳-肩距離には約8%の固有差があるため、側が切り替わったら窓をまたげない。
    private var windowSide: Side? = nil

    // MARK: - 公開API

    /// 新しいキャリブレーションセッションを開始する。
    /// 以前の基準値は上書きされる。
    mutating func start() {
        accumulatedAngles = []
        accumulatedDistances = []
        accumulatedPoints = []
        isAccumulating = false
        accumulatedDuration = 0
        lastSampleTime = 0
        dropoutActive = false
        windowSide = nil
    }

    /// 人物検出状態を処理する。
    /// - Parameters:
    ///   - sample: PostureAnalyzer からの角度サンプル（有効な角度がない場合は nil）
    ///   - presence: 人物検出状態（デバウンス確定済みの値を渡す。猶予期間中は .personDetected）
    ///   - now: 現在の時刻間隔
    ///   - points: 可視化ポイント（6点: 0左肩 1右肩 2左耳 3右耳 4近傍耳 5近傍肩）
    /// - Returns: キャリブレーション進捗状態
    mutating func ingest(sample: AngleSample?, presence: DetectionPresence, now: TimeInterval, points: [CGPoint] = []) -> CalibrationProgress {
        // 有効サンプルがある場合は通常蓄積。personMissing はキーポイント脱落と同一扱いで
        // 脱落許容時間（dropoutTolerance）内は時間凍結、超過でリセット（else 節）。
        if let sample = sample, presence == .personDetected {
            if !isAccumulating {
                // 最初の有効サンプルで蓄積を開始
                accumulatedAngles = [sample.nearAngleDegrees]
                accumulatedDistances = [sample.nearDistance]
                accumulatedPoints = [points]
                isAccumulating = true
                accumulatedDuration = 0
                lastSampleTime = now
                windowSide = sample.nearSide
                return .accumulating(elapsed: 0)
            }

            // 安定性チェック: 直近 windowSize サンプルの中央値比。
            // フレーム単位の Vision ジッタは吸収し、実際の姿勢移動のみ検出する。
            // 近側の切り替わりは角度が安定していても即時リセット（FQ1: 側をまたぐ距離窓は汚染される）
            let window = Array(accumulatedAngles.suffix(Self.stabilityWindowSize))
            let median = Self.median(of: window)
            if abs(sample.nearAngleDegrees - median) > Self.angleResetThresholdDegrees || sample.nearSide != windowSide {
                // 不安定な場合は蓄積をリセット（角度崩れ・側切り替わりは脱落と違い即時リセット）
                accumulatedAngles = [sample.nearAngleDegrees]
                accumulatedDistances = [sample.nearDistance]
                accumulatedPoints = [points]
                accumulatedDuration = 0
                lastSampleTime = now
                dropoutActive = false
                windowSide = sample.nearSide
                return .accumulating(elapsed: 0)
            }

            // 前回の有効サンプルからの経過時間分だけ蓄積を進める。
            // 脱落区間（dropoutActive）の時間は計上しない。復帰前の脱落が
            // 許容時間を超えている場合は姿勢崩れとしてリセットする。
            if dropoutActive {
                if now - lastSampleTime > Self.dropoutTolerance {
                    accumulatedAngles = [sample.nearAngleDegrees]
                    accumulatedDistances = [sample.nearDistance]
                    accumulatedPoints = [points]
                    accumulatedDuration = 0
                    lastSampleTime = now
                    dropoutActive = false
                    windowSide = sample.nearSide
                    return .accumulating(elapsed: 0)
                }
                dropoutActive = false
            } else {
                accumulatedDuration += now - lastSampleTime
            }
            lastSampleTime = now

            // 新しい角度を蓄積に追加
            accumulatedAngles.append(sample.nearAngleDegrees)
            accumulatedDistances.append(sample.nearDistance)
            if !points.isEmpty {
                accumulatedPoints.append(points)
            }

            // 蓄積が完了に十分かチェック（有効サンプルで requiredStableDuration 分たまったら完了）
            // 加算の浮動小数誤差に -1e-9 で余裕（TimedConditionGate と同パターン）
            if accumulatedDuration >= Self.requiredStableDuration - 1e-9 {
                // 蓄積された角度の平均を計算
                let average = accumulatedAngles.reduce(0.0, +) / Double(accumulatedAngles.count)
                let averageDistance = accumulatedDistances.reduce(0.0, +) / Double(accumulatedDistances.count)
                let finalPoints = accumulatedPoints.last ?? []
                let completedProgress = CalibrationProgress.completed(referenceNearAngleDegrees: average, referenceDistance: averageDistance, referenceSide: sample.nearSide, referencePoints: finalPoints)

                resetAccumulation()
                return completedProgress
            }
            return .accumulating(elapsed: min(accumulatedDuration, Self.requiredStableDuration))
        } else {
            // 角度サンプルなし、または人物未検出（personMissing）。キーポイント脱落と同一扱い:
            // 直近の有効サンプルからの経過が許容時間以内なら蓄積を保持し時間だけを凍結、
            // 許容を超えたら姿勢崩れとしてリセットする。
            if isAccumulating && now - lastSampleTime > Self.dropoutTolerance {
                resetAccumulation()
                return .waitingForPerson
            }
            if isAccumulating {
                dropoutActive = true
                return .accumulating(elapsed: min(accumulatedDuration, Self.requiredStableDuration))
            }
            return .waitingForPerson
        }
    }

    // MARK: - プライベートメソッド

    private mutating func resetAccumulation() {
        accumulatedAngles = []
        accumulatedDistances = []
        accumulatedPoints = []
        isAccumulating = false
        accumulatedDuration = 0
        lastSampleTime = 0
        dropoutActive = false
        windowSide = nil
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
