import Foundation

struct PostureAnalyzer {
    /// 姿勢フレームを分析して猫背かどうかを判定する。
    ///
    /// 近傍側の選択: 両側が有効な場合、x座標が小さい方の肩を近傍側とする（Q9）。
    /// 片側のみ有効な場合、その側が自動的に近傍側となる（Q11）。
    ///
    /// 角度計算: 肩から耳へのベクトルと垂直方向 (0,1) の角度。
    /// 結果は鋭角 0〜90度。移動平均フィルタなし（Q12）。
    ///
    /// 信頼度 < 0.5 のキーポイントは除外される（4.5）。
    /// カメラの取り付け角度は基準値に吸収される。
    func analyze(
        frame: PoseFrame,
        referenceNearAngleDegrees: Double?,
        slouchDeltaThresholdDegrees: Double,
        distanceMetric: DistanceMetric? = nil,          // ロック側ペアと基準距離（8.3 までは未使用）
        slouchDistanceThresholdPercent: Double = 8.0,   // 距離閾値%（8.3 までは未使用）
        previousNearSide: Side? = nil
    ) -> (sample: AngleSample?, verdict: PostureVerdict) {

        // ステップ1: 各側の有効なキーポイントペアを特定（信頼度 >= 0.5）
        let leftValid = isValidPair(ear: frame.leftEar, shoulder: frame.leftShoulder)
        let rightValid = isValidPair(ear: frame.rightEar, shoulder: frame.rightShoulder)

        // ステップ2: 近傍側の選択
        var nearSide: Side?
        var nearEar: Keypoint?
        var nearShoulder: Keypoint?
        var farSideDetected = false

        if leftValid && rightValid {
            let lx = frame.leftShoulder!.x
            let rx = frame.rightShoulder!.x

            // ヒステリシスの導入: 前回の判定がある場合、一定の閾値を超えない限り維持する
            let hysteresisThreshold = 0.02 // 座標系(0-1)における2%のバッファ

            if let prev = previousNearSide {
                let diff = rx - lx
                if abs(diff) < hysteresisThreshold {
                    // 差が閾値内の場合は前回の判定を維持（小刻みな切り替わり防止）
                    nearSide = prev
                } else {
                    nearSide = diff > 0 ? .left : .right
                }
            } else {
                nearSide = lx < rx ? .left : .right
            }

            nearEar = (nearSide == .left) ? frame.leftEar : frame.rightEar
            nearShoulder = (nearSide == .left) ? frame.leftShoulder : frame.rightShoulder
            farSideDetected = true
        } else if leftValid {
            nearSide = .left
            nearEar = frame.leftEar
            nearShoulder = frame.leftShoulder
            farSideDetected = false
        } else if rightValid {
            nearSide = .right
            nearEar = frame.rightEar
            nearShoulder = frame.rightShoulder
            farSideDetected = false
        } else {
            return (nil, .insufficientKeypoints)
        }

        // ステップ3: 鋭角を計算（0〜90度）
        let vx = nearEar!.x - nearShoulder!.x
        let vy = nearEar!.y - nearShoulder!.y
        let length = sqrt(vx * vx + vy * vy)
        guard length > 0 else { return (nil, .insufficientKeypoints) }

        let cosTheta = vy / length
        let clampedCos = max(-1.0, min(1.0, cosTheta))
        let thetaRadians = acos(clampedCos)
        let thetaDegrees = thetaRadians * 180.0 / .pi
        let acuteAngle = min(thetaDegrees, 180.0 - thetaDegrees)

        // ステップ3b: 耳-肩距離（前出し検出の第2指標）。
        // 監視中（distanceMetric あり）は角度の近側選択と独立にロック側ペアで評価する（FQ1）。
        // ロック側ペアが信頼度未満等で使用できないフレームでは距離条件をスキップし、
        // 角度のみで判定を継続する。校正中（nil）は近側の素値を記録するだけ。
        var reportedDistance = length
        var distanceOverThreshold = false
        if let metric = distanceMetric, metric.referenceDistance > 0 {
            let lockEar = (metric.side == .left) ? frame.leftEar : frame.rightEar
            let lockShoulder = (metric.side == .left) ? frame.leftShoulder : frame.rightShoulder
            if isValidPair(ear: lockEar, shoulder: lockShoulder) {
                let dx = lockEar!.x - lockShoulder!.x
                let dy = lockEar!.y - lockShoulder!.y
                let lockDistance = sqrt(dx * dx + dy * dy)
                reportedDistance = lockDistance
                distanceOverThreshold = lockDistance >= metric.referenceDistance * (1.0 + slouchDistanceThresholdPercent / 100.0)
            }
        }

        // ステップ4: 判定を決定（角度 OR 距離基準比・FQ6）
        let referenceAngle = referenceNearAngleDegrees ?? 0.0
        let delta = acuteAngle - referenceAngle
        let verdict: PostureVerdict = (delta >= slouchDeltaThresholdDegrees || distanceOverThreshold) ? .slouchCandidate : .good

        return (
            AngleSample(
                nearSide: nearSide!,
                nearAngleDegrees: acuteAngle,
                farSideDetected: farSideDetected,
                nearDistance: reportedDistance
            ),
            verdict
        )
    }

    private func isValidPair(ear: Keypoint?, shoulder: Keypoint?) -> Bool {
        guard let ear = ear,
              let shoulder = shoulder,
              ear.confidence >= minimumKeypointConfidence,
              shoulder.confidence >= minimumKeypointConfidence
        else {
            return false
        }
        return true
    }
}
