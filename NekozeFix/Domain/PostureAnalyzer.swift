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
        slouchDeltaThresholdDegrees: Double
    ) -> (sample: AngleSample?, verdict: PostureVerdict) {

        // ステップ1: 各側の有効なキーポイントペアを特定（信頼度 >= 0.5）
        let leftValid = isValidPair(ear: frame.leftEar, shoulder: frame.leftShoulder)
        let rightValid = isValidPair(ear: frame.rightEar, shoulder: frame.rightShoulder)

        // ステップ2: 近傍側の選択
        // - 両側有効: 肩のx座標で比較（Q9）
        // - 片側有効: 検出側が近傍側（Q11）
        // - どちらも無効: キーポイント不足
        var nearSide: Side?
        var nearEar: Keypoint?
        var nearShoulder: Keypoint?
        var farSideDetected = false

        if leftValid && rightValid {
            // 両側有効: 肩のx座標で近傍側を選択
            let lx = frame.leftShoulder!.x
            let rx = frame.rightShoulder!.x
            if lx < rx {
                nearSide = .left
                nearEar = frame.leftEar
                nearShoulder = frame.leftShoulder
                farSideDetected = true
            } else if rx < lx {
                nearSide = .right
                nearEar = frame.rightEar
                nearShoulder = frame.rightShoulder
                farSideDetected = true
            } else {
                // x座標が同じ場合: 左をデフォルトとする（Q9）
                nearSide = .left
                nearEar = frame.leftEar
                nearShoulder = frame.leftShoulder
                farSideDetected = true
            }
        } else if leftValid {
            // 左側のみ有効: 自動的に近傍側として扱う（Q11）
            nearSide = .left
            nearEar = frame.leftEar
            nearShoulder = frame.leftShoulder
            farSideDetected = false
        } else if rightValid {
            // 右側のみ有効: 自動的に近傍側として扱う（Q11）
            nearSide = .right
            nearEar = frame.rightEar
            nearShoulder = frame.rightShoulder
            farSideDetected = false
        } else {
            // 有効なキーポイントなし
            return (nil, .insufficientKeypoints)
        }

        // ステップ3: 鋭角を計算（0〜90度）
        // 肩から耳へのベクトル: v = (ear.x - shoulder.x, ear.y - shoulder.y)
        // cos(θ) = v · (0,1) / |v| = v.y / |v|
        // θ = acos(clamp(v.y / |v|, -1, 1))
        // 結果は鋭角（Q10）
        let vx = nearEar!.x - nearShoulder!.x
        let vy = nearEar!.y - nearShoulder!.y
        let length = sqrt(vx * vx + vy * vy)
        guard length > 0 else { return (nil, .insufficientKeypoints) }

        let cosTheta = vy / length
        let clampedCos = max(-1.0, min(1.0, cosTheta))
        let thetaRadians = acos(clampedCos)
        let thetaDegrees = thetaRadians * 180.0 / .pi
        let acuteAngle = min(thetaDegrees, 180.0 - thetaDegrees)  // 鋭角を保証

        // ステップ4: 判定を決定
        // カメラの取り付け角度は基準値に吸収される。
        // 絶対的な垂直方向との比較は行わない。
        let referenceAngle = referenceNearAngleDegrees ?? 0.0
        let delta = acuteAngle - referenceAngle
        let verdict: PostureVerdict = delta >= slouchDeltaThresholdDegrees ? .slouchCandidate : .good

        return (
            AngleSample(
                nearSide: nearSide!,
                nearAngleDegrees: acuteAngle,
                farSideDetected: farSideDetected
            ),
            verdict
        )
    }

    /// 耳と肩のキーポイントが両方存在し、信頼度閾値を満たす場合に true を返す。
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