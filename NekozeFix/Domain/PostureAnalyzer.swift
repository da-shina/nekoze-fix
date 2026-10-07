import Foundation

struct PostureAnalyzer {
    /// 近側選択のヒステリシス幅（度）。旧位置0.02則 ≒ 耳肩長0.2正規化で約5.7° と等価。
    private static let nearSideHysteresisDegrees = 5.0

    /// 姿勢フレームを分析して猫背かどうかを判定する。
    ///
    /// 近傍側の選択: 両側が有効な場合、解決済み基準線との鋭角が大きい
    /// （鈍角側の）ペアを近傍側とする（要件4.7・感度優先）。
    /// 角度差がヒステリシス幅未満の場合は前回の選択を維持する。
    /// 片側のみ有効な場合、その側が自動的に近傍側となる（Q11）。
    ///
    /// 角度計算: 肩から耳へのベクトルと解決済み基準ベクトル（重力→両肩ライン直交上向き法線→
    /// 画像垂直 (0,1) の順に同ファイル内 `resolve` で解決）の角度。
    /// 結果は鋭角 0〜90度。移動平均フィルタなし（Q12）。
    ///
    /// 信頼度ゲートは minimumConfidence 引数で受ける（Session が向き別閾値を注入。
    /// 既定は minimumKeypointConfidence。要件4.5/4.6）。
    /// カメラの取り付け角度は基準値に吸収される。
    ///
    /// 重力は値として受け取る（Domain は Services を参照しない）。nil は代替解決を意味し、
    /// gravity 以外の入力が同一なら従来と同一の近側・距離・判定を返す（不変条件）。
    /// captureAngleDegrees は capture用回転角（度、任意）。重力はデバイスセンサ座標系で
    /// 得られるがキーポイントは回転済みバッファ座標系に存在するため、重力由来の基準値のみを
    /// バッファ座標系へ(θ−90°)回転させる（nil・未確定時は無回転で従来通り）。代替経路は回転しない。
    func analyze(
        frame: PoseFrame,
        referenceNearAngleDegrees: Double?,
        slouchDeltaThresholdDegrees: Double,
        distanceMetric: DistanceMetric? = nil,          // ロック側ペアと基準距離（8.3 までは未使用）
        slouchDistanceThresholdPercent: Double = 8.0,   // 距離閾値%（8.3 までは未使用）
        previousNearSide: Side? = nil,
        gravityInKeypointSpace: SIMD2<Double>? = nil,    // MotionService 変換済みか nil（12.2）
        captureAngleDegrees: Double? = nil,               // capture用回転角（度）。nil は無回転
        minimumConfidence: Double = minimumKeypointConfidence // 向き別信頼度ゲート（Session が注入）
    ) -> (sample: AngleSample?, verdict: PostureVerdict, referenceVector: ResolvedReferenceVector) {

        // ステップ1: 各側の有効なキーポイントペアを特定（向き別ゲート。Session が同値で事前フィルタ済み）
        let leftValid = isValidPair(ear: frame.leftEar, shoulder: frame.leftShoulder, minimumConfidence: minimumConfidence)
        let rightValid = isValidPair(ear: frame.rightEar, shoulder: frame.rightShoulder, minimumConfidence: minimumConfidence)

        // ステップ2: 解決済み基準ベクトルを先に確定する（近側選択に両側の角度が必要なため）。
        // resolve はフレームのみに依存し選択に依存しない（単一解決）。
        let resolvedReference = Self.resolve(gravityInKeypointSpace: gravityInKeypointSpace, frame: frame, captureAngleDegrees: captureAngleDegrees, minimumConfidence: minimumConfidence)
        let perpX = resolvedReference.vector.x
        let perpY = resolvedReference.vector.y

        // ステップ3: 近側の選択（鈍角側優先・感度優先。要件4.7）
        var nearSide: Side?
        var nearEar: Keypoint?
        var nearShoulder: Keypoint?

        if leftValid && rightValid {
            // 縮退ペア（耳＝肩の完全一致）は選択対象から除外する。
            // 長さを 0 度に読み替えると、ヒステリシスが測定不能側を維持し
            // 反対側の有効角度を捨ててしまう。報告角度は後段でガードする。
            let leftAngle = Self.earShoulderGeometry(ear: frame.leftEar!, shoulder: frame.leftShoulder!, perpX: perpX, perpY: perpY)?.angle
            let rightAngle = Self.earShoulderGeometry(ear: frame.rightEar!, shoulder: frame.rightShoulder!, perpX: perpX, perpY: perpY)?.angle

            if let prev = previousNearSide,
               let l = leftAngle, let r = rightAngle,
               abs(l - r) < Self.nearSideHysteresisDegrees {
                // 差が閾値内の場合は前回の判定を維持（小刻みな切り替わり防止）
                nearSide = prev
            } else if let l = leftAngle, let r = rightAngle {
                nearSide = (l >= r) ? .left : .right
            } else if leftAngle != nil {
                nearSide = .left
            } else if rightAngle != nil {
                nearSide = .right
            } else {
                return (nil, .insufficientKeypoints, resolvedReference)
            }

            nearEar = (nearSide == .left) ? frame.leftEar : frame.rightEar
            nearShoulder = (nearSide == .left) ? frame.leftShoulder : frame.rightShoulder
        } else if leftValid {
            nearSide = .left
            nearEar = frame.leftEar
            nearShoulder = frame.leftShoulder
        } else if rightValid {
            nearSide = .right
            nearEar = frame.rightEar
            nearShoulder = frame.rightShoulder
        } else {
            return (nil, .insufficientKeypoints, resolvedReference)
        }

        // ステップ4: 選択側の幾何量を取得（0〜90度の鋭角＋長さ。報告値の単一算出点）
        guard let geometry = Self.earShoulderGeometry(ear: nearEar!, shoulder: nearShoulder!, perpX: perpX, perpY: perpY) else {
            return (nil, .insufficientKeypoints, resolvedReference)
        }
        let acuteAngle = geometry.angle
        let length = geometry.length

        // ステップ4b: 耳-肩距離（前出し検出の第2指標）。
        // 監視中（distanceMetric あり）は角度の近側選択と独立にロック側ペアで評価する（FQ1）。
        // ロック側ペアが信頼度未満等で使用できないフレームでは距離条件をスキップし、
        // 角度のみで判定を継続する。校正中（nil）は近側の素値を記録するだけ。
        var reportedDistance = length
        var distanceOverThreshold = false

        if let metric = distanceMetric, metric.referenceDistance > 0 {
            let lockEar = (metric.side == .left) ? frame.leftEar : frame.rightEar
            let lockShoulder = (metric.side == .left) ? frame.leftShoulder : frame.rightShoulder
            if isValidPair(ear: lockEar, shoulder: lockShoulder, minimumConfidence: minimumConfidence) {
                let dx = lockEar!.x - lockShoulder!.x
                let dy = lockEar!.y - lockShoulder!.y
                let lockDistance = sqrt(dx * dx + dy * dy)
                reportedDistance = lockDistance
                distanceOverThreshold = lockDistance >= metric.referenceDistance * (1.0 + slouchDistanceThresholdPercent / 100.0)
            }
            // ロック側ペアが使用できないフレームは距離条件をスキップし角度のみで判定（反対側代用なし・要件4.1）。
        }

        // ステップ5: 判定を決定（角度 OR 距離基準比・FQ6）
        let referenceAngle = referenceNearAngleDegrees ?? 0.0
        let delta = acuteAngle - referenceAngle
        let verdict: PostureVerdict = (delta >= slouchDeltaThresholdDegrees || distanceOverThreshold) ? .slouchCandidate : .good

        return (
            AngleSample(
                nearSide: nearSide!,
                nearAngleDegrees: acuteAngle,
                nearDistance: reportedDistance
            ),
            verdict,
            resolvedReference
        )
    }

    /// 重力・肩直交・画像垂直の三段解決を純粋に所有する（要件4.1）。
    ///
    /// 入力は重力値（デバイスセンサ座標系）・capture角（度、任意）とフレームのみ。時刻・状態を持たない。
    /// 解決順序は gravity → shoulderLine → imageVertical に固定する。
    /// 重力由来の基準値のみ capture角θでバッファ座標系へ(θ−90°)回転させる（センサ基準角のため）。
    /// 肩直交・画像垂直は元々バッファ座標系のため回転しない。
    /// Analyzer からのみ呼ぶ。Session は直接呼ばない（単一解決）。
    private static func resolve(
        gravityInKeypointSpace: SIMD2<Double>?,
        frame: PoseFrame,
        captureAngleDegrees: Double? = nil,
        minimumConfidence: Double
    ) -> ResolvedReferenceVector {
        // 第一段: 重力（有効な単位化可能ベクトルのみ採用）
        if let gravity = gravityInKeypointSpace {
            let length = sqrt(gravity.x * gravity.x + gravity.y * gravity.y)
            if length.isFinite && length > 1e-9 {
                let rotated = rotateToBufferSpace(gravity / length, captureAngleDegrees: captureAngleDegrees)
                return ResolvedReferenceVector(vector: rotated, source: .gravity)
            }
        }
        // 第二段: 両肩ライン直交上向き法線（従来式を移設）
        if let ls = frame.leftShoulder, let rs = frame.rightShoulder,
           ls.confidence >= minimumConfidence, rs.confidence >= minimumConfidence {
            let leftShoulder = (ls.x <= rs.x) ? ls : rs
            let rightShoulder = (ls.x <= rs.x) ? rs : ls
            let sdx = rightShoulder.x - leftShoulder.x
            let sdy = rightShoulder.y - leftShoulder.y
            let shoulderDist = sqrt(sdx * sdx + sdy * sdy)
            if shoulderDist > 0 {
                // (sdx, sdy) に直交し、Vision座標系で上向き (+y方向) の単位ベクトル:
                // 内積: sdx * (-sdy) + sdy * sdx = 0 (直角)
                // sdx >= 0 のため sdx / shoulderDist >= 0 (+y方向)
                return ResolvedReferenceVector(vector: ReferenceVector(-sdy / shoulderDist, sdx / shoulderDist), source: .shoulderLine)
            }
        }
        // 第三段（終端）: 画像垂直
        return ResolvedReferenceVector(vector: ReferenceVector(0.0, 1.0), source: .imageVertical)
    }

    /// デバイス座標系ベクトルをバッファ座標系へ回転させる（capture角θの(θ−90°)回転）。
    /// coordinator角はセンサ基準であり、ポートレートで90°・ランドスケープで0°/180°を取る
    /// （センサがランドスケープネイティブ。WWDC23 10106）。nil（未確定）では恒等。
    /// 回転は長さを保存する。
    static func rotateToBufferSpace(_ v: SIMD2<Double>, captureAngleDegrees: Double?) -> SIMD2<Double> {
        guard let degrees = captureAngleDegrees else { return v }
        let rad = (degrees - 90) * .pi / 180.0
        return SIMD2<Double>(
            v.x * cos(rad) - v.y * sin(rad),
            v.x * sin(rad) + v.y * cos(rad)
        )
    }

    /// 肩→耳ベクトルの幾何量（基準線との鋭角 0〜90度＋ベクトル長）。縮退（長さ0）は nil。
    private static func earShoulderGeometry(ear: Keypoint, shoulder: Keypoint, perpX: Double, perpY: Double) -> (angle: Double, length: Double)? {
        let vx = ear.x - shoulder.x
        let vy = ear.y - shoulder.y
        let length = sqrt(vx * vx + vy * vy)
        guard length > 0 else { return nil }
        let clampedCos = max(-1.0, min(1.0, (vx * perpX + vy * perpY) / length))
        let thetaDegrees = acos(clampedCos) * 180.0 / .pi
        return (min(thetaDegrees, 180.0 - thetaDegrees), length)
    }

    private func isValidPair(ear: Keypoint?, shoulder: Keypoint?, minimumConfidence: Double) -> Bool {
        guard let ear = ear,
              let shoulder = shoulder,
              ear.confidence >= minimumConfidence,
              shoulder.confidence >= minimumConfidence
        else {
            return false
        }
        return true
    }
}
