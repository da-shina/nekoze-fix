import Foundation

struct PostureAnalyzer {
    /// 姿勢フレームを分析して猫背かどうかを判定する。
    ///
    /// 近傍側の選択: 両側が有効な場合、x座標が小さい方の肩を近傍側とする（Q9）。
    /// 片側のみ有効な場合、その側が自動的に近傍側となる（Q11）。
    ///
    /// 角度計算: 肩から耳へのベクトルと基準上向きベクトル（両肩検出時は両肩ライン直交上向き法線、片側時は画像垂直 (0,1)）の角度。
    /// アスペクト比補正: Vision 正規化座標は非正方形フレームでも [0,1]×[0,1] に正規化されるため、
    /// x/y のスケールが異なる。角度計算前に x 成分に AR（画像幅/画像高）を適用して等方座標系に変換する（ADR 0008）。
    /// 距離指標はパーセント比較のため正規化座標のまま補正しない。
    ///
    /// 信頼度 < 0.5 のキーポイントは除外される（4.5）。
    /// カメラの取り付け角度は基準値に吸収される。
    func analyze(
        frame: PoseFrame,
        referenceNearAngleDegrees: Double?,
        slouchDeltaThresholdDegrees: Double,
        videoAspectRatio: Double = 4.0 / 3.0,
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

        // ステップ3: 基準法線ベクトル（両肩ライン直交上向き法線、片側時(0,1)フォールバック）と鋭角を計算（0〜90度）
        // Vision 正規化座標は非正方形でも [0,1]×[0,1] に正規化されるため、x 成分に AR を適用して等方座標系に変換する。
        // 距離指標は正規化座標のまま（補正なし。パーセント比較のため座標系に依存しない）。
        let arScale = videoAspectRatio
        let perpX: Double
        let perpY: Double
        if let ls = frame.leftShoulder, let rs = frame.rightShoulder,
           ls.confidence >= minimumKeypointConfidence, rs.confidence >= minimumKeypointConfidence {
            let leftShoulder = (ls.x <= rs.x) ? ls : rs
            let rightShoulder = (ls.x <= rs.x) ? rs : ls
            let sdx = (rightShoulder.x - leftShoulder.x) * arScale
            let sdy = rightShoulder.y - leftShoulder.y
            let shoulderDist = sqrt(sdx * sdx + sdy * sdy)
            if shoulderDist > 0 {
                perpX = -sdy / shoulderDist
                perpY = sdx / shoulderDist
            } else {
                perpX = 0.0
                perpY = 1.0
            }
        } else {
            perpX = 0.0
            perpY = 1.0
        }

        let vx = (nearEar!.x - nearShoulder!.x) * arScale
        let vy = nearEar!.y - nearShoulder!.y
        let length = sqrt(vx * vx + vy * vy)
        guard length > 0 else { return (nil, .insufficientKeypoints) }

        let cosTheta = (vx * perpX + vy * perpY) / length
        let clampedCos = max(-1.0, min(1.0, cosTheta))
        let thetaRadians = acos(clampedCos)
        let thetaDegrees = thetaRadians * 180.0 / .pi
        let acuteAngle = min(thetaDegrees, 180.0 - thetaDegrees)

        // ステップ3b: 耳-肩距離（前出し検出の第2指標）。
        // 監視中（distanceMetric あり）は角度の近側選択と独立にロック側ペアで評価する（FQ1）。
        // ロック側ペアが信頼度未満等で使用できないフレームでは距離条件をスキップし、
        // 角度のみで判定を継続する。校正中（nil）は近側の素値を記録するだけ。
        // 距離は正規化座標のまま計算（アスペクト比補正なし。パーセント比較のため座標系に依存しない）。
        let nearDx = nearEar!.x - nearShoulder!.x
        let nearDy = nearEar!.y - nearShoulder!.y
        var reportedDistance = sqrt(nearDx * nearDx + nearDy * nearDy)
        var distanceOverThreshold = false
        var farAngleDegrees: Double? = nil
        var farDistanceValue: Double? = nil

        // 両側検出時に遠側の角度・距離も計算
        if farSideDetected {
            let farEar = (nearSide! == .left) ? frame.rightEar : frame.leftEar
            let farShoulder = (nearSide! == .left) ? frame.rightShoulder : frame.leftShoulder
            if isValidPair(ear: farEar, shoulder: farShoulder) {
                let fvx = (farEar!.x - farShoulder!.x) * arScale
                let fvy = farEar!.y - farShoulder!.y
                let flength = sqrt(fvx * fvx + fvy * fvy)
                if flength > 0 {
                    let fcosTheta = (fvx * perpX + fvy * perpY) / flength
                    let fclampedCos = max(-1.0, min(1.0, fcosTheta))
                    let fthetaDegrees = acos(fclampedCos) * 180.0 / .pi
                    farAngleDegrees = min(fthetaDegrees, 180.0 - fthetaDegrees)
                    // 距離は正規化座標のまま（近側と同様に補正なし）
                    let farDx = farEar!.x - farShoulder!.x
                    let farDy = farEar!.y - farShoulder!.y
                    farDistanceValue = sqrt(farDx * farDx + farDy * farDy)
                }
            }
        }

        if let metric = distanceMetric, metric.referenceDistance > 0 {
            let lockEar = (metric.side == .left) ? frame.leftEar : frame.rightEar
            let lockShoulder = (metric.side == .left) ? frame.leftShoulder : frame.rightShoulder
            if isValidPair(ear: lockEar, shoulder: lockShoulder) {
                let dx = lockEar!.x - lockShoulder!.x
                let dy = lockEar!.y - lockShoulder!.y
                let lockDistance = sqrt(dx * dx + dy * dy)
                reportedDistance = lockDistance
                distanceOverThreshold = lockDistance >= metric.referenceDistance * (1.0 + slouchDistanceThresholdPercent / 100.0)
            } else if let fallback = metric.fallbackReferenceDistance, fallback > 0 {
                // ロック側欠測時: 反対側のペアでフォールバック評価
                let fallbackSide: Side = (metric.side == .left) ? .right : .left
                let fbEar = (fallbackSide == .left) ? frame.leftEar : frame.rightEar
                let fbShoulder = (fallbackSide == .left) ? frame.leftShoulder : frame.rightShoulder
                if isValidPair(ear: fbEar, shoulder: fbShoulder) {
                    let dx = fbEar!.x - fbShoulder!.x
                    let dy = fbEar!.y - fbShoulder!.y
                    let fbDistance = sqrt(dx * dx + dy * dy)
                    reportedDistance = fbDistance
                    distanceOverThreshold = fbDistance >= fallback * (1.0 + slouchDistanceThresholdPercent / 100.0)
                }
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
                nearDistance: reportedDistance,
                farAngleDegrees: farAngleDegrees,
                farDistance: farDistanceValue
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
