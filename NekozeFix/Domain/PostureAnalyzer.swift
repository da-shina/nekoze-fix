import Foundation
import CoreGraphics

/// 近側キーポイントを選び、物理的な垂直方向（重力方向）に対する耳ー肩ラインの角度を計算する。
/// I/O なし。
struct PostureAnalyzer {

    /// 姿勢フレームを解析し、角度サンプルと猫背判定結果を返す。
    /// - Parameters:
    ///   - frame: Vision から抽出されたキーポイント群。
    ///   - verticalVector: 重力方向を画像平面に投影した単位ベクトル。
    ///   - slouchThresholdDegrees: 猫背判定の角度閾値。
    ///   - distanceMetric: 校正時にロックした側と基準距離。nil またはペア欠測時は距離判定をスキップ。
    ///   - slouchDistanceThresholdPercent: 猫背判定の距離基準比閾値（%）。
    ///   - previousNearSide: 前フレームの近側。ヒステリシス適用に使用。
    /// - Returns: (AngleSample?, PostureVerdict)
    func analyze(
        frame: PoseFrame,
        verticalVector: CGPoint,
        slouchThresholdDegrees: Double,
        distanceMetric: DistanceMetric? = nil,
        slouchDistanceThresholdPercent: Double = 8.0,
        previousNearSide: Side? = nil
    ) -> (sample: AngleSample?, verdict: PostureVerdict) {

        // 1. 信頼度フィルタリング済みの有効なペアを抽出
        let leftPair = (ear: frame.leftEar, shoulder: frame.leftShoulder)
        let rightPair = (ear: frame.rightEar, shoulder: frame.rightShoulder)

        let leftValid = isPairValid(leftPair)
        let rightValid = isPairValid(rightPair)

        // 両側無効なら判定不能
        guard leftValid || rightValid else {
            return (nil, .insufficientKeypoints)
        }

        // 2. 近側の決定 (Q9, Q11)
        let nearSide: Side
        if leftValid && rightValid {
            // 両側有効な場合、肩の x 座標が小さい方を近側とする
            // ヒステリシス: 差が極小な場合は前回の判定を維持（チャタリング防止）
            let lx = leftPair.shoulder?.x ?? 0
            let rx = rightPair.shoulder?.x ?? 0
            let diff = rx - lx

            if let prev = previousNearSide, abs(diff) < 0.02 {
                nearSide = prev
            } else {
                nearSide = diff >= 0 ? .left : .right
            }
        } else {
            // 片側のみ有効ならその側を自動的に近側とする
            nearSide = leftValid ? .left : .right
        }

        // 3. 角度計算
        let nearPair = (nearSide == .left) ? leftPair : rightPair
        let nearAngle = calculateAcuteAngle(ear: nearPair.ear, shoulder: nearPair.shoulder, vertical: verticalVector)

        // 遠側のデータ（両側検出時のみ）
        var farAngle: Double? = nil
        var farDist: Double? = nil
        if leftValid && rightValid {
            let farPair = (nearSide == .left) ? rightPair : leftPair
            farAngle = calculateAcuteAngle(ear: farPair.ear, shoulder: farPair.shoulder, vertical: verticalVector)
            farDist = calculateDistance(ear: farPair.ear, shoulder: farPair.shoulder)
        }

        // 4. 距離指標の評価 (FQ1)
        // 監視中の距離計算は、角度の近側とは独立に、校正時にロックした側で行う。
        var distanceVerdict: Bool = false
        var evaluatedDistance: Double = 0.0

        if let metric = distanceMetric {
            let lockedPair = (metric.side == .left) ? leftPair : rightPair
            if isPairValid(lockedPair) {
                let dist = calculateDistance(ear: lockedPair.ear, shoulder: lockedPair.shoulder)
                evaluatedDistance = dist
                let ratioPercent = (dist / metric.referenceDistance - 1.0) * 100.0
                distanceVerdict = ratioPercent >= slouchDistanceThresholdPercent
            } else {
                // ロック側が欠測した場合は距離判定をスキップ（角度のみで判定）
                // sample.nearDistance にはフォールバックとして近側の距離を入れる
                evaluatedDistance = calculateDistance(ear: nearPair.ear, shoulder: nearPair.shoulder)
            }
        } else {
            // 校正中などは metric がないため、単純に近側の距離を記録
            evaluatedDistance = calculateDistance(ear: nearPair.ear, shoulder: nearPair.shoulder)
        }

        // 5. 最終判定 (OR 判定: FQ6)
        let angleVerdict = nearAngle >= slouchThresholdDegrees
        let isSlouch = angleVerdict || distanceVerdict
        let finalVerdict: PostureVerdict = isSlouch ? .slouchCandidate : .good

        let sample = AngleSample(
            nearSide: nearSide,
            nearAngleDegrees: nearAngle,
            farSideDetected: leftValid && rightValid,
            nearDistance: evaluatedDistance,
            farAngleDegrees: farAngle,
            farDistance: farDist
        )

        return (sample, finalVerdict)
    }

    // MARK: - Private Helpers

    private func isPairValid(_ pair: (ear: Keypoint?, shoulder: Keypoint?)) -> Bool {
        guard let ear = pair.ear, let shoulder = pair.shoulder else { return false }
        return ear.confidence >= minimumKeypointConfidence &&
               shoulder.confidence >= minimumKeypointConfidence
    }

    private func calculateAcuteAngle(ear: Keypoint?, shoulder: Keypoint?, vertical: CGPoint) -> Double {
        guard let ear = ear, let shoulder = shoulder else { return 0 }

        // 肩から耳へのベクトル v
        let vx = ear.x - shoulder.x
        let vy = ear.y - shoulder.y

        // ベクトルの大きさ
        let vLen = sqrt(vx * vx + vy * vy)
        guard vLen > 0 else { return 0 }

        // 単位ベクトル
        let ux = vx / vLen
        let uy = vy / vLen

        // 垂直ベクトルとの内積 (垂直ベクトルは単位ベクトルであることを想定)
        let dot = ux * vertical.x + uy * vertical.y

        // cos(theta) を [-1, 1] にクランプ
        let cosTheta = max(-1.0, min(1.0, dot))

        // 角度 (ラジアン)
        let thetaRad = acos(cosTheta)

        // 度数に変換
        var degrees = thetaRad * 180.0 / .pi

        // 鋭角 0-90度に変換 (Q10)
        // dot < 0 の場合は鈍角になっているので、反転させる
        if degrees > 90.0 {
            degrees = 180.0 - degrees
        }

        return degrees
    }

    private func calculateDistance(ear: Keypoint?, shoulder: Keypoint?) -> Double {
        guard let ear = ear, let shoulder = shoulder else { return 0 }
        let dx = ear.x - shoulder.x
        let dy = ear.y - shoulder.y
        return sqrt(dx * dx + dy * dy)
    }
}
